/**
 * BlandCallbackController_Test
 * Unit tests for the Bland AI inbound webhook handler.
 * Covers: interested, no_answer, voicemail, busy, declined, DNC detection.
 */
@IsTest
private class BlandCallbackController_Test {

    // ─── Test data helpers ───────────────────────────────────────────────────

    private static Carrier__c makeCarrier() {
        Carrier__c c = new Carrier__c(
            Name              = 'Test Carrier LLC',
            Contact_Phone__c  = '5555550100',
            State__c          = 'TX',
            Equipment_Types__c = 'Dry Van',
            Time_Zone__c      = 'America/Chicago',
            FMCSA_Authority_Status__c = 'Active',
            Insurance_Expiry__c = Date.today().addYears(1)
        );
        insert c;
        return c;
    }

    private static Load__c makeLoad(Carrier__c carrier) {
        Load__c l = new Load__c(
            Status__c           = 'AI Calling',
            Origin_City__c      = 'Dallas',
            Origin_State__c     = 'TX',
            Destination_City__c = 'Chicago',
            Destination_State__c = 'IL',
            Equipment_Type__c   = 'Dry Van',
            Pickup_Date__c      = DateTime.now().addDays(2),
            Target_Rate__c      = 2500.00,
            AI_Calling_Active__c = true
        );
        insert l;
        return l;
    }

    private static Call_Log__c makeCallLog(Load__c load, Carrier__c carrier, String callId) {
        Call_Log__c log = new Call_Log__c(
            Load__c      = load.Id,
            Carrier__c   = carrier.Id,
            Bland_Call_ID__c = callId,
            Called_At__c = DateTime.now(),
            Outcome__c   = 'Pending'
        );
        insert log;
        return log;
    }

    private static Load_Carrier_Interest__c makeInterest(Load__c load, Carrier__c carrier) {
        Load_Carrier_Interest__c lci = new Load_Carrier_Interest__c(
            Load__c    = load.Id,
            Carrier__c = carrier.Id,
            Status__c  = 'Called',
            Priority__c = 1,
            Retry_Count__c = 1
        );
        insert lci;
        return lci;
    }

    private static void sendCallback(Map<String, Object> payload) {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/atlas/bland/callback';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(payload));
        req.addHeader('Content-Type', 'application/json');
        RestContext.request  = req;
        RestContext.response = new RestResponse();
        BlandCallbackController.handleCallback();
    }

    // ─── Tests ───────────────────────────────────────────────────────────────

    @IsTest
    static void testInterestedOutcome_movesLoadToPendingHandoff() {
        Carrier__c carrier = makeCarrier();
        Load__c load       = makeLoad(carrier);
        Call_Log__c log    = makeCallLog(load, carrier, 'CALL-001');
        Load_Carrier_Interest__c lci = makeInterest(load, carrier);

        Map<String, Object> payload = new Map<String, Object>{
            'call_id'       => 'CALL-001',
            'outcome'       => 'interested',
            'transcript'    => 'Yes I can take that load.',
            'recording_url' => 'https://bland.ai/recordings/CALL-001',
            'duration'      => 120,
            'variables'     => new Map<String, Object>{
                'load_id'     => load.Id,
                'interest_id' => lci.Id,
                'carrier_id'  => carrier.Id
            }
        };

        Test.startTest();
        sendCallback(payload);
        Test.stopTest();

        Load__c updatedLoad = [SELECT Status__c, Booked_Carrier__c FROM Load__c WHERE Id = :load.Id];
        System.assertEquals('Pending Handoff', updatedLoad.Status__c,
            'Load should move to Pending Handoff');
        System.assertEquals(carrier.Id, updatedLoad.Booked_Carrier__c,
            'Booked carrier should be set');

        Call_Log__c updatedLog = [SELECT Outcome__c, Handoff_Triggered__c FROM Call_Log__c WHERE Id = :log.Id];
        System.assertEquals('Interested', updatedLog.Outcome__c);
        System.assert(updatedLog.Handoff_Triggered__c, 'Handoff flag should be set');

        List<Task> tasks = [SELECT Subject FROM Task WHERE WhatId = :load.Id];
        System.assertFalse(tasks.isEmpty(), 'A handoff task should be created');
        System.assert(tasks[0].Subject.contains('interested'), 'Task subject should mention interest');
    }

    @IsTest
    static void testNoAnswerOutcome_schedulesRetry() {
        Carrier__c carrier = makeCarrier();
        Load__c load       = makeLoad(carrier);
        Call_Log__c log    = makeCallLog(load, carrier, 'CALL-002');
        Load_Carrier_Interest__c lci = makeInterest(load, carrier);

        Map<String, Object> payload = new Map<String, Object>{
            'call_id'    => 'CALL-002',
            'outcome'    => 'no_answer',
            'transcript' => '',
            'duration'   => 0,
            'variables'  => new Map<String, Object>{
                'load_id'     => load.Id,
                'interest_id' => lci.Id,
                'carrier_id'  => carrier.Id
            }
        };

        Test.startTest();
        sendCallback(payload);
        Test.stopTest();

        Load_Carrier_Interest__c updated = [
            SELECT Status__c, Next_Retry_At__c, Retry_Count__c
            FROM Load_Carrier_Interest__c WHERE Id = :lci.Id
        ];
        System.assertEquals('Retry Pending', updated.Status__c, 'Should be scheduled for retry');
        System.assertNotEquals(null, updated.Next_Retry_At__c, 'Retry time should be set');

        Load__c unchangedLoad = [SELECT Status__c FROM Load__c WHERE Id = :load.Id];
        System.assertEquals('AI Calling', unchangedLoad.Status__c, 'Load should stay in AI Calling');
    }

    @IsTest
    static void testVoicemailOutcome_schedulesRetry() {
        Carrier__c carrier = makeCarrier();
        Load__c load       = makeLoad(carrier);
        Call_Log__c log    = makeCallLog(load, carrier, 'CALL-003');
        Load_Carrier_Interest__c lci = makeInterest(load, carrier);

        Map<String, Object> payload = new Map<String, Object>{
            'call_id'    => 'CALL-003',
            'outcome'    => 'voicemail',
            'transcript' => 'Left voicemail.',
            'duration'   => 30,
            'variables'  => new Map<String, Object>{
                'load_id' => load.Id, 'interest_id' => lci.Id, 'carrier_id' => carrier.Id
            }
        };

        Test.startTest();
        sendCallback(payload);
        Test.stopTest();

        Load_Carrier_Interest__c updated = [SELECT Status__c FROM Load_Carrier_Interest__c WHERE Id = :lci.Id];
        System.assertEquals('Retry Pending', updated.Status__c);
    }

    @IsTest
    static void testDeclinedOutcome_noRetry() {
        Carrier__c carrier = makeCarrier();
        Load__c load       = makeLoad(carrier);
        Call_Log__c log    = makeCallLog(load, carrier, 'CALL-004');
        Load_Carrier_Interest__c lci = makeInterest(load, carrier);

        Map<String, Object> payload = new Map<String, Object>{
            'call_id'    => 'CALL-004',
            'outcome'    => 'declined',
            'transcript' => 'Not interested.',
            'duration'   => 45,
            'variables'  => new Map<String, Object>{
                'load_id' => load.Id, 'interest_id' => lci.Id, 'carrier_id' => carrier.Id
            }
        };

        Test.startTest();
        sendCallback(payload);
        Test.stopTest();

        Load_Carrier_Interest__c updated = [SELECT Status__c FROM Load_Carrier_Interest__c WHERE Id = :lci.Id];
        System.assertEquals('Declined', updated.Status__c, 'Declined should not trigger retry');
    }

    @IsTest
    static void testDNCDetection_setsDoNotCall() {
        Carrier__c carrier = makeCarrier();
        Load__c load       = makeLoad(carrier);
        Call_Log__c log    = makeCallLog(load, carrier, 'CALL-005');
        Load_Carrier_Interest__c lci = makeInterest(load, carrier);

        Map<String, Object> payload = new Map<String, Object>{
            'call_id'    => 'CALL-005',
            'outcome'    => 'declined',
            'transcript' => 'Please stop calling me and remove me from your list.',
            'duration'   => 20,
            'variables'  => new Map<String, Object>{
                'load_id' => load.Id, 'interest_id' => lci.Id, 'carrier_id' => carrier.Id
            }
        };

        Test.startTest();
        sendCallback(payload);
        Test.stopTest();

        Carrier__c updatedCarrier = [SELECT Do_Not_Call__c FROM Carrier__c WHERE Id = :carrier.Id];
        System.assert(updatedCarrier.Do_Not_Call__c, 'DNC should be set when carrier requests removal');
    }

    @IsTest
    static void testMissingCallId_returns400() {
        Carrier__c carrier = makeCarrier();
        Load__c load       = makeLoad(carrier);

        Map<String, Object> payload = new Map<String, Object>{
            'outcome'  => 'interested',
            'duration' => 60
        };

        Test.startTest();
        sendCallback(payload);
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Missing call_id should return 400');
    }

    @IsTest
    static void testExhaustedRetry_marksExhausted() {
        Carrier__c carrier = makeCarrier();
        Load__c load       = makeLoad(carrier);
        Call_Log__c log    = makeCallLog(load, carrier, 'CALL-006');

        // Simulate a carrier that has already been retried 4 times
        Load_Carrier_Interest__c lci = new Load_Carrier_Interest__c(
            Load__c     = load.Id,
            Carrier__c  = carrier.Id,
            Status__c   = 'Called',
            Priority__c = 1,
            Retry_Count__c = 4
        );
        insert lci;

        Map<String, Object> payload = new Map<String, Object>{
            'call_id'    => 'CALL-006',
            'outcome'    => 'no_answer',
            'transcript' => '',
            'duration'   => 0,
            'variables'  => new Map<String, Object>{
                'load_id' => load.Id, 'interest_id' => lci.Id, 'carrier_id' => carrier.Id
            }
        };

        Test.startTest();
        sendCallback(payload);
        Test.stopTest();

        Load_Carrier_Interest__c updated = [SELECT Status__c FROM Load_Carrier_Interest__c WHERE Id = :lci.Id];
        System.assertEquals('Exhausted', updated.Status__c, 'Should be marked Exhausted after 5 attempts');
    }
}
