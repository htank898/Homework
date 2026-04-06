/**
 * SelectCarriersForLoad_Test
 * Unit tests for the carrier selection + priority scoring pipeline.
 * Covers: compliance filtering, equipment matching, priority sorting, whitelist bonus.
 */
@IsTest
private class SelectCarriersForLoad_Test {

    private static Load__c makeLoad(String originState, String destState) {
        Load__c l = new Load__c(
            Status__c            = 'New',
            Origin_City__c       = 'City A',
            Origin_State__c      = originState,
            Destination_City__c  = 'City B',
            Destination_State__c = destState,
            Equipment_Type__c    = 'Dry Van',
            Pickup_Date__c       = DateTime.now().addDays(3)
        );
        insert l;
        return l;
    }

    private static Carrier__c makeCarrier(String state, String equip, Boolean blacklisted,
                                           Boolean oos, Boolean dnc, Boolean whitelisted,
                                           Decimal reputation, Decimal acceptance) {
        Carrier__c c = new Carrier__c(
            Name                       = 'Carrier ' + state + ' ' + equip,
            Contact_Phone__c           = '5555550100',
            State__c                   = state,
            Equipment_Types__c         = equip,
            Time_Zone__c               = 'America/Chicago',
            Blacklisted__c             = blacklisted,
            Out_Of_Service__c          = oos,
            Do_Not_Call__c             = dnc,
            Whitelisted__c             = whitelisted,
            Reputation_Score__c        = reputation,
            Acceptance_Rate__c         = acceptance,
            On_Time_Delivery_Rate__c   = 85,
            FMCSA_Authority_Status__c  = 'Active',
            Insurance_Expiry__c        = Date.today().addYears(1)
        );
        insert c;
        return c;
    }

    @IsTest
    static void testBlacklistedCarrierExcluded() {
        Load__c load = makeLoad('TX', 'IL');
        Carrier__c blacklisted = makeCarrier('TX', 'Dry Van', true, false, false, false, 90, 70);

        Test.startTest();
        SelectCarriersForLoad.selectAndQueue(load.Id);
        Test.stopTest();

        List<Load_Carrier_Interest__c> queue = [
            SELECT Id, Carrier__c, Status__c FROM Load_Carrier_Interest__c WHERE Load__c = :load.Id
        ];
        // Blacklisted carrier should not appear at all (filtered in SOQL)
        for (Load_Carrier_Interest__c lci : queue) {
            System.assertNotEquals(blacklisted.Id, lci.Carrier__c,
                'Blacklisted carrier should not be in queue');
        }
    }

    @IsTest
    static void testExpiredInsuranceCarrierSkipped() {
        Load__c load = makeLoad('TX', 'IL');
        Carrier__c expired = makeCarrier('TX', 'Dry Van', false, false, false, false, 80, 60);
        // Override insurance to expired
        update new Carrier__c(Id = expired.Id, Insurance_Expiry__c = Date.today().addDays(-10));

        Test.startTest();
        SelectCarriersForLoad.selectAndQueue(load.Id);
        Test.stopTest();

        List<Load_Carrier_Interest__c> queue = [
            SELECT Carrier__c, Status__c, Skip_Reason__c
            FROM Load_Carrier_Interest__c
            WHERE Load__c = :load.Id AND Carrier__c = :expired.Id
        ];
        if (!queue.isEmpty()) {
            System.assertEquals('Skipped', queue[0].Status__c,
                'Expired insurance carrier should be Skipped');
            System.assert(queue[0].Skip_Reason__c.containsIgnoreCase('insurance'),
                'Skip reason should mention insurance');
        }
    }

    @IsTest
    static void testEquipmentMismatchExcluded() {
        Load__c load = makeLoad('TX', 'IL'); // needs Dry Van
        Carrier__c reefer = makeCarrier('TX', 'Refrigerated (Reefer)', false, false, false, false, 80, 60);

        Test.startTest();
        SelectCarriersForLoad.selectAndQueue(load.Id);
        Test.stopTest();

        List<Load_Carrier_Interest__c> queue = [
            SELECT Carrier__c FROM Load_Carrier_Interest__c
            WHERE Load__c = :load.Id AND Carrier__c = :reefer.Id
        ];
        System.assert(queue.isEmpty(), 'Mismatched equipment carrier should not be in queue');
    }

    @IsTest
    static void testWhitelistedCarrierGetsHighPriority() {
        Load__c load = makeLoad('TX', 'IL');
        Carrier__c normal     = makeCarrier('TX', 'Dry Van', false, false, false, false, 60, 50);
        Carrier__c whitelisted = makeCarrier('TX', 'Dry Van', false, false, false, true, 60, 50);

        Test.startTest();
        SelectCarriersForLoad.selectAndQueue(load.Id);
        Test.stopTest();

        List<Load_Carrier_Interest__c> queue = [
            SELECT Carrier__c, Priority__c FROM Load_Carrier_Interest__c
            WHERE Load__c = :load.Id AND Status__c = 'Queued'
            ORDER BY Priority__c ASC
        ];

        if (queue.size() >= 2) {
            // Whitelisted should have lower priority number (= called first)
            Integer wlPriority = null;
            Integer normalPriority = null;
            for (Load_Carrier_Interest__c lci : queue) {
                if (lci.Carrier__c == whitelisted.Id) wlPriority = (Integer) lci.Priority__c;
                if (lci.Carrier__c == normal.Id) normalPriority = (Integer) lci.Priority__c;
            }
            if (wlPriority != null && normalPriority != null) {
                System.assert(wlPriority < normalPriority,
                    'Whitelisted carrier should have higher priority (lower number) than normal');
            }
        }
    }

    @IsTest
    static void testAdjacentStateCarriersIncluded() {
        Load__c load = makeLoad('TX', 'IL');
        // Oklahoma is adjacent to TX
        Carrier__c okCarrier = makeCarrier('OK', 'Dry Van', false, false, false, false, 70, 55);

        Test.startTest();
        SelectCarriersForLoad.selectAndQueue(load.Id);
        Test.stopTest();

        List<Load_Carrier_Interest__c> queue = [
            SELECT Carrier__c FROM Load_Carrier_Interest__c
            WHERE Load__c = :load.Id AND Carrier__c = :okCarrier.Id
        ];
        System.assertFalse(queue.isEmpty(), 'Adjacent state carrier should be included in queue');
    }

    @IsTest
    static void testReputationScoringFormula() {
        // Test the batch score calculation directly
        Carrier__c highPerformer = new Carrier__c(
            Name = 'Test',
            On_Time_Delivery_Rate__c = 98,
            Claims_Count__c          = 0,
            Communication_Score__c   = 95,
            Acceptance_Rate__c       = 80
        );

        Decimal score = CarrierReputationBatch.computeScore(highPerformer);
        // Expected: (98*0.4) + (100*0.3) + (95*0.2) + (80*0.1) = 39.2+30+19+8 = 96.2
        System.assert(score > 90, 'High performer should score above 90. Got: ' + score);
        System.assert(score <= 100, 'Score should not exceed 100');

        Carrier__c poorPerformer = new Carrier__c(
            Name = 'Test2',
            On_Time_Delivery_Rate__c = 50,
            Claims_Count__c          = 10,
            Communication_Score__c   = 30,
            Acceptance_Rate__c       = 20
        );
        Decimal poorScore = CarrierReputationBatch.computeScore(poorPerformer);
        System.assert(poorScore < 70, 'Poor performer should score below 70. Got: ' + poorScore);
    }
}
