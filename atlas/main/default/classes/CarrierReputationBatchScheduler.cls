/**
 * CarrierReputationBatchScheduler
 * Schedulable wrapper for CarrierReputationBatch.
 * Activated via: System.schedule('Atlas - Carrier Reputation Batch', '0 0 2 * * ?', new CarrierReputationBatchScheduler());
 */
public with sharing class CarrierReputationBatchScheduler implements Schedulable {
    public void execute(SchedulableContext ctx) {
        Database.executeBatch(new CarrierReputationBatch(), 200);
    }
}
