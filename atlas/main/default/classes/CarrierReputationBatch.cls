/**
 * CarrierReputationBatch
 * Nightly batch job that recalculates Reputation_Score__c for all active carriers.
 *
 * Scoring formula:
 *   Reputation_Score = (On_Time_Delivery_Rate * 0.40)
 *                    + (max(0, 100 - Claims_Count * 5) * 0.30)
 *                    + (Communication_Score * 0.20)
 *                    + (Acceptance_Rate * 0.10)
 *
 * Schedule: nightly at 02:00 UTC via CarrierReputationBatchScheduler.
 */
public with sharing class CarrierReputationBatch implements Database.Batchable<SObject> {

    private static final Integer BATCH_SIZE = 200;

    public Database.QueryLocator start(Database.BatchableContext ctx) {
        return Database.getQueryLocator([
            SELECT Id, On_Time_Delivery_Rate__c, Claims_Count__c,
                   Communication_Score__c, Acceptance_Rate__c,
                   Blacklisted__c, Do_Not_Call__c
            FROM Carrier__c
            WHERE Blacklisted__c = false
        ]);
    }

    public void execute(Database.BatchableContext ctx, List<Carrier__c> carriers) {
        List<Carrier__c> toUpdate = new List<Carrier__c>();

        for (Carrier__c c : carriers) {
            Decimal score = computeScore(c);
            toUpdate.add(new Carrier__c(Id = c.Id, Reputation_Score__c = score));
        }

        if (!toUpdate.isEmpty()) update toUpdate;
    }

    public void finish(Database.BatchableContext ctx) {
        System.debug('CarrierReputationBatch: Completed. Job ID=' + ctx.getJobId());
    }

    /**
     * Schedules this batch to run nightly at 02:00 UTC.
     * Call once via anonymous Apex to activate the schedule.
     */
    public static void scheduleDailyRun() {
        String cronExpr = '0 0 2 * * ?'; // 02:00 UTC every day
        System.schedule('Atlas - Carrier Reputation Batch', cronExpr,
            new CarrierReputationBatchScheduler());
    }

    // ─── Scoring ────────────────────────────────────────────────────────────

    @TestVisible
    static Decimal computeScore(Carrier__c c) {
        Decimal onTime    = safe(c.On_Time_Delivery_Rate__c, 80);
        Decimal claims    = safe(c.Claims_Count__c, 0);
        Decimal commScore = safe(c.Communication_Score__c, 50);
        Decimal acceptance = safe(c.Acceptance_Rate__c, 50);

        Decimal claimsPenalty = Math.max(0, 100 - (claims * 5));

        Decimal score = (onTime      * 0.40)
                      + (claimsPenalty * 0.30)
                      + (commScore   * 0.20)
                      + (acceptance  * 0.10);

        // Clamp to 0–100
        return Math.min(100, Math.max(0, score.setScale(2)));
    }

    private static Decimal safe(Decimal val, Decimal defaultVal) {
        return (val != null) ? val : defaultVal;
    }
}
