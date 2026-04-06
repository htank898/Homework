/**
 * CallRetryScheduler
 * Runs every 5 minutes and processes Load_Carrier_Interest__c records
 * where Next_Retry_At__c <= NOW and Status__c = 'Retry Pending'.
 *
 * Retry backoff schedule (managed by BlandCallbackController on incoming webhooks):
 *   Attempt 1 : Immediate
 *   Attempt 2 : +15 minutes
 *   Attempt 3 : +1 hour
 *   Attempt 4 : +4 hours
 *   Attempt 5 : Exhausted
 *
 * Activation (run once via anonymous Apex):
 *   CallRetryScheduler.scheduleEveryFiveMinutes();
 */
public with sharing class CallRetryScheduler implements Schedulable {

    private static final Integer MAX_RETRIES = 5;

    // Backoff in minutes per attempt index
    private static final List<Integer> BACKOFF_MINUTES = new List<Integer>{
        0, 15, 60, 240, 0 // attempt 1,2,3,4 — attempt 5 = exhausted
    };

    public void execute(SchedulableContext ctx) {
        processRetryQueue();
    }

    @Future(callout=true)
    public static void processRetryQueueAsync() {
        processRetryQueue();
    }

    public static void processRetryQueue() {
        DateTime now = DateTime.now();

        List<Load_Carrier_Interest__c> due = [
            SELECT Id, Load__c, Carrier__c, Status__c, Retry_Count__c, Next_Retry_At__c,
                   Load__r.Id, Load__r.Name, Load__r.Origin_City__c, Load__r.Origin_State__c,
                   Load__r.Destination_City__c, Load__r.Destination_State__c,
                   Load__r.Pickup_Date__c, Load__r.Equipment_Type__c, Load__r.Target_Rate__c,
                   Load__r.Status__c,
                   Carrier__r.Id, Carrier__r.Name, Carrier__r.Contact_Phone__c,
                   Carrier__r.Time_Zone__c, Carrier__r.Last_Called__c,
                   Carrier__r.Do_Not_Call__c, Carrier__r.Blacklisted__c, Carrier__r.Out_Of_Service__c
            FROM Load_Carrier_Interest__c
            WHERE Status__c = 'Retry Pending'
              AND Next_Retry_At__c <= :now
              AND Load__r.Status__c = 'AI Calling'
            ORDER BY Next_Retry_At__c ASC
            LIMIT 50
        ];

        for (Load_Carrier_Interest__c interest : due) {
            // Skip if carrier has been blacklisted or DNC'd since queuing
            if (interest.Carrier__r.Do_Not_Call__c || interest.Carrier__r.Blacklisted__c
                    || interest.Carrier__r.Out_Of_Service__c) {
                interest.Status__c     = 'Skipped';
                interest.Skip_Reason__c = 'Compliance status changed after queuing';
                update interest;
                continue;
            }

            Integer retryCount = (interest.Retry_Count__c != null)
                ? (Integer) interest.Retry_Count__c : 0;

            if (retryCount >= MAX_RETRIES) {
                interest.Status__c = 'Exhausted';
                update interest;
                checkIfAllExhausted(interest.Load__c);
                continue;
            }

            // Re-set to Queued so BlandOutboundService can pick it up
            interest.Status__c        = 'Queued';
            interest.Next_Retry_At__c = null;
            update interest;

            // Initiate the call
            BlandOutboundService.initiateCall(interest);
        }
    }

    /**
     * If all carriers for a load are Exhausted or Skipped, move load back to New
     * so an agent can review and retry, and create an escalation task.
     */
    private static void checkIfAllExhausted(Id loadId) {
        Integer activeCount = [
            SELECT COUNT() FROM Load_Carrier_Interest__c
            WHERE Load__c = :loadId
              AND Status__c IN ('Queued', 'Called', 'Retry Pending')
        ];

        if (activeCount == 0) {
            update new Load__c(
                Id              = loadId,
                Status__c       = 'New',
                AI_Calling_Active__c = false
            );
            insert new Task(
                WhatId      = loadId,
                Subject     = 'All carriers exhausted — manual booking or retry required',
                Status      = 'Open',
                Priority    = 'High',
                ActivityDate = Date.today()
            );
        }
    }

    /**
     * Returns the backoff duration (in minutes) for a given retry attempt number (1-indexed).
     */
    public static Integer getBackoffMinutes(Integer attemptNumber) {
        Integer idx = Math.min(attemptNumber - 1, BACKOFF_MINUTES.size() - 1);
        return BACKOFF_MINUTES.get(idx);
    }

    /**
     * Schedules this job to run every 5 minutes using 12 cron schedules (one per 5-min slot per hour).
     * Run once via Anonymous Apex to activate.
     */
    public static void scheduleEveryFiveMinutes() {
        for (Integer minute = 0; minute < 60; minute += 5) {
            String cronExpr = '0 ' + minute + ' * * * ?';
            String jobName  = 'Atlas - Call Retry ' + String.valueOf(minute).leftPad(2, '0');
            try {
                System.schedule(jobName, cronExpr, new CallRetryScheduler());
            } catch (Exception ex) {
                System.debug('CallRetryScheduler: Could not schedule ' + jobName + ' — ' + ex.getMessage());
            }
        }
    }
}
