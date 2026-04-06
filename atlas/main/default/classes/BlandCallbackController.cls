/**
 * BlandCallbackController
 * Apex REST endpoint that receives call completion webhooks from Bland AI.
 *
 * Endpoint: POST /services/apexrest/atlas/bland/callback
 *
 * Expected payload:
 * {
 *   "call_id":        "abc123",
 *   "outcome":        "interested" | "not_available" | "no_answer" | "declined" | "voicemail" | "busy",
 *   "transcript":     "...",
 *   "recording_url":  "https://...",
 *   "duration":       87,
 *   "variables": {
 *     "load_id":     "a0X...",
 *     "interest_id": "a1Y...",
 *     "carrier_id":  "a2Z..."
 *   }
 * }
 *
 * On "interested" outcome:
 *   - Load moves to "Pending Handoff"
 *   - Task created for assigned agent
 *   - Chatter post on load
 *
 * On all other outcomes:
 *   - Call_Log__c updated
 *   - Retry logic scheduled based on outcome type
 */
@RestResource(urlMapping='/atlas/bland/callback')
global with sharing class BlandCallbackController {

    // Outcome → internal status mapping
    private static final Map<String, String> OUTCOME_MAP = new Map<String, String>{
        'interested'     => 'Interested',
        'not_available'  => 'Not Available',
        'no_answer'      => 'No Answer',
        'declined'       => 'Declined',
        'voicemail'      => 'Voicemail',
        'busy'           => 'Busy'
    };

    @HttpPost
    global static void handleCallback() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;

        try {
            Map<String, Object> payload =
                (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());

            String callId   = (String) payload.get('call_id');
            String outcome  = ((String) payload.get('outcome')).toLowerCase();
            String transcript  = (String) payload.get('transcript');
            String recordingUrl = (String) payload.get('recording_url');
            Integer duration = payload.get('duration') != null
                ? ((Decimal) payload.get('duration')).intValue() : 0;

            Map<String, Object> variables =
                (Map<String, Object>) payload.get('variables');
            Id loadId     = variables != null ? (Id) variables.get('load_id')     : null;
            Id interestId = variables != null ? (Id) variables.get('interest_id') : null;
            Id carrierId  = variables != null ? (Id) variables.get('carrier_id')  : null;

            if (String.isBlank(callId)) {
                res.statusCode = 400;
                res.responseBody = Blob.valueOf('{"error":"call_id required"}');
                return;
            }

            // Find and update the Call_Log__c
            Call_Log__c log = findOrCreateLog(callId, loadId, carrierId);
            String internalOutcome = OUTCOME_MAP.containsKey(outcome)
                ? OUTCOME_MAP.get(outcome) : 'No Answer';

            log.Outcome__c        = internalOutcome;
            log.Transcript__c     = transcript;
            log.Recording_URL__c  = recordingUrl;
            log.Duration_Seconds__c = duration;

            if ('Interested'.equals(internalOutcome)) {
                log.Handoff_Triggered__c = true;
            }
            update log;

            // Update the Load_Carrier_Interest__c
            if (interestId != null) {
                updateInterestRecord(interestId, internalOutcome, outcome);
            }

            // Handle outcome-specific logic
            if ('Interested'.equals(internalOutcome) && loadId != null && carrierId != null) {
                handleInterestedCarrier(loadId, carrierId);
            } else if (needsRetry(outcome) && interestId != null && loadId != null) {
                scheduleRetry(interestId, outcome);
            }

            // If carrier asked to be removed from calls, set DNC
            if (carrierRequestedDNC(transcript) && carrierId != null) {
                update new Carrier__c(Id = carrierId, Do_Not_Call__c = true);
            }

            res.statusCode = 200;
            res.responseBody = Blob.valueOf('{"status":"ok"}');

        } catch (Exception ex) {
            System.debug('BlandCallbackController: Exception — ' + ex.getMessage()
                + '\n' + ex.getStackTraceString());
            res.statusCode = 500;
            res.responseBody = Blob.valueOf('{"error":"' + ex.getMessage() + '"}');
        }
    }

    // ─── Private helpers ────────────────────────────────────────────────────

    private static Call_Log__c findOrCreateLog(String callId, Id loadId, Id carrierId) {
        List<Call_Log__c> existing = [
            SELECT Id, Load__c, Carrier__c, Outcome__c, Transcript__c,
                   Recording_URL__c, Duration_Seconds__c, Handoff_Triggered__c
            FROM Call_Log__c
            WHERE Bland_Call_ID__c = :callId
            LIMIT 1
        ];

        if (!existing.isEmpty()) return existing[0];

        // Create a new log if not found (handles edge case where outbound failed to log)
        Call_Log__c newLog = new Call_Log__c(
            Bland_Call_ID__c = callId,
            Load__c     = loadId,
            Carrier__c  = carrierId,
            Called_At__c = DateTime.now()
        );
        insert newLog;
        return newLog;
    }

    private static void updateInterestRecord(Id interestId, String internalOutcome, String rawOutcome) {
        Load_Carrier_Interest__c lci = [
            SELECT Id, Status__c, Retry_Count__c FROM Load_Carrier_Interest__c
            WHERE Id = :interestId LIMIT 1
        ];
        lci.Status__c = internalOutcome;
        update lci;
    }

    private static void handleInterestedCarrier(Id loadId, Id carrierId) {
        Load__c load = [
            SELECT Id, Status__c, Assigned_Agent__c, Name
            FROM Load__c WHERE Id = :loadId LIMIT 1
        ];

        // Only transition if still in AI Calling state
        if ('AI Calling'.equals(load.Status__c)) {
            load.Status__c       = 'Pending Handoff';
            load.Booked_Carrier__c = carrierId;
            load.AI_Calling_Active__c = false;
            update load;

            // Create handoff task for assigned agent
            insert new Task(
                WhatId      = loadId,
                OwnerId     = load.Assigned_Agent__c != null
                                ? load.Assigned_Agent__c : UserInfo.getUserId(),
                Subject     = 'Carrier interested — close the deal',
                Description = 'A carrier has expressed interest via Bland AI outreach. '
                            + 'Review the call transcript and confirm booking.',
                Status      = 'Open',
                Priority    = 'High',
                ActivityDate = Date.today()
            );

            // Chatter post
            ConnectApi.FeedItemInput feedItem = new ConnectApi.FeedItemInput();
            feedItem.subjectId = loadId;
            ConnectApi.MessageBodyInput body = new ConnectApi.MessageBodyInput();
            ConnectApi.TextSegmentInput seg  = new ConnectApi.TextSegmentInput();
            seg.text = 'Bland AI found an interested carrier for load ' + load.Name
                     + '. Status moved to Pending Handoff — agent action required.';
            body.messageSegments = new List<ConnectApi.MessageSegmentInput>{ seg };
            feedItem.body = body;

            try {
                ConnectApi.ChatterFeeds.postFeedElement(Network.getNetworkId(), feedItem);
            } catch (Exception ex) {
                System.debug('BlandCallbackController: Chatter post failed — ' + ex.getMessage());
            }
        }
    }

    private static Boolean needsRetry(String outcome) {
        return outcome == 'no_answer' || outcome == 'voicemail' || outcome == 'busy';
    }

    private static void scheduleRetry(Id interestId, String outcome) {
        Load_Carrier_Interest__c lci = [
            SELECT Id, Retry_Count__c FROM Load_Carrier_Interest__c
            WHERE Id = :interestId LIMIT 1
        ];

        Integer currentCount = (lci.Retry_Count__c != null)
            ? (Integer) lci.Retry_Count__c : 0;
        Integer nextAttempt  = currentCount + 1;

        if (nextAttempt >= 5) {
            lci.Status__c = 'Exhausted';
            update lci;
            return;
        }

        Integer backoffMinutes = 'busy'.equals(outcome)
            ? 5  // Busy signal: retry in 5 minutes
            : CallRetryScheduler.getBackoffMinutes(nextAttempt);

        lci.Status__c        = 'Retry Pending';
        lci.Next_Retry_At__c = DateTime.now().addMinutes(backoffMinutes);
        lci.Retry_Count__c   = nextAttempt;
        update lci;
    }

    private static Boolean carrierRequestedDNC(String transcript) {
        if (String.isBlank(transcript)) return false;
        String lower = transcript.toLowerCase();
        return lower.contains('remove me from your list')
            || lower.contains('stop calling')
            || lower.contains('do not call')
            || lower.contains('take me off your list')
            || lower.contains('unsubscribe');
    }
}
