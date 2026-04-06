/**
 * SelectCarriersForLoad
 * Carrier selection and priority scoring pipeline.
 *
 * Pipeline steps:
 *  1. Hard compliance filters (blacklisted, OOS, DNC, expired insurance, etc.)
 *  2. Equipment type + proximity filter (origin state match + adjacent states)
 *  3. Priority score calculation
 *  4. Timezone call-window deferred scheduling
 *  5. Create Load_Carrier_Interest__c records ordered by priority
 */
public with sharing class SelectCarriersForLoad {

    // Scoring weights
    private static final Decimal W_ACCEPTANCE    = 0.35;
    private static final Decimal W_REPUTATION    = 0.25;
    private static final Decimal W_ON_TIME       = 0.20;
    private static final Decimal W_LANE_MATCH    = 0.15;
    private static final Decimal W_RECENCY       = 0.05;
    private static final Decimal WHITELIST_BONUS = 20.0;

    // Adjacent states map — expand as needed
    private static final Map<String, Set<String>> ADJACENT_STATES = new Map<String, Set<String>>{
        'TX' => new Set<String>{ 'OK', 'NM', 'AR', 'LA' },
        'IL' => new Set<String>{ 'WI', 'IN', 'MO', 'IA', 'KY' },
        'CA' => new Set<String>{ 'OR', 'NV', 'AZ' },
        'FL' => new Set<String>{ 'GA', 'AL' },
        'OH' => new Set<String>{ 'MI', 'IN', 'KY', 'WV', 'PA' },
        'GA' => new Set<String>{ 'FL', 'AL', 'TN', 'NC', 'SC' },
        'PA' => new Set<String>{ 'NY', 'NJ', 'DE', 'MD', 'WV', 'OH' },
        'TN' => new Set<String>{ 'KY', 'VA', 'NC', 'GA', 'AL', 'MS', 'AR', 'MO' },
        'MO' => new Set<String>{ 'IA', 'IL', 'KY', 'TN', 'AR', 'OK', 'KS', 'NE' }
    };

    /**
     * Main entry point. Selects and queues carriers for a load.
     * Called from BlandOutboundService when the queue is empty.
     *
     * @param loadId  The Load__c Id to process
     */
    @InvocableMethod(label='Select Carriers for Load'
                     description='Runs the carrier selection pipeline and builds the call queue')
    public static void selectAndQueueInvocable(List<Id> loadIds) {
        for (Id loadId : loadIds) {
            selectAndQueue(loadId);
        }
    }

    public static void selectAndQueue(Id loadId) {
        Load__c load = [
            SELECT Id, Name, Origin_State__c, Destination_State__c,
                   Equipment_Type__c, Target_Rate__c
            FROM Load__c
            WHERE Id = :loadId
            LIMIT 1
        ];

        // Gather candidate states
        Set<String> targetStates = new Set<String>{ load.Origin_State__c };
        if (ADJACENT_STATES.containsKey(load.Origin_State__c)) {
            targetStates.addAll(ADJACENT_STATES.get(load.Origin_State__c));
        }

        // Query candidate carriers — hard filters applied in SOQL where possible
        List<Carrier__c> candidates = [
            SELECT Id, Name, State__c, Equipment_Types__c, Preferred_Lanes__c,
                   Acceptance_Rate__c, Reputation_Score__c, On_Time_Delivery_Rate__c,
                   Last_Called__c, Whitelisted__c, Blacklisted__c, Do_Not_Call__c,
                   Out_Of_Service__c, FMCSA_Authority_Status__c, Insurance_Expiry__c,
                   Safety_Rating__c, Compliance_Override__c, Time_Zone__c
            FROM Carrier__c
            WHERE State__c IN :targetStates
              AND Blacklisted__c = false
              AND Do_Not_Call__c = false
              AND Out_Of_Service__c = false
            ORDER BY Reputation_Score__c DESC NULLS LAST
            LIMIT 200
        ];

        // Delete existing Queued records for this load to avoid duplicates
        delete [
            SELECT Id FROM Load_Carrier_Interest__c
            WHERE Load__c = :loadId AND Status__c = 'Queued'
        ];

        String laneKey = load.Origin_State__c + '-' + load.Destination_State__c;
        List<ScoredCarrier> scored = new List<ScoredCarrier>();

        for (Carrier__c c : candidates) {
            // Equipment filter
            if (!carriersEquipmentMatches(c, load.Equipment_Type__c)) continue;

            // Remaining compliance checks
            String skipReason = getComplianceSkipReason(c);
            if (skipReason != null && !c.Compliance_Override__c) {
                // Still create an Interest record so agents can see it was excluded
                scored.add(new ScoredCarrier(c, 0, skipReason));
                continue;
            }

            // Score
            Decimal score = computePriorityScore(c, laneKey);
            scored.add(new ScoredCarrier(c, score, null));
        }

        // Sort: nulls (skipped) go last; whitelisted bonus already in score
        scored.sort();

        // Create Load_Carrier_Interest__c records
        List<Load_Carrier_Interest__c> interests = new List<Load_Carrier_Interest__c>();
        Integer priority = 1;

        for (ScoredCarrier sc : scored) {
            Load_Carrier_Interest__c lci = new Load_Carrier_Interest__c(
                Load__c     = loadId,
                Carrier__c  = sc.carrier.Id,
                Priority__c = priority++,
                Status__c   = sc.skipReason != null ? 'Skipped' : 'Queued',
                Skip_Reason__c = sc.skipReason,
                Retry_Count__c = 0
            );

            // If outside call window for this carrier, set next retry time
            if (sc.skipReason == null
                    && !CallWindowUtil.isWithinCallWindow(sc.carrier.Time_Zone__c)) {
                lci.Status__c        = 'Retry Pending';
                lci.Next_Retry_At__c = CallWindowUtil.nextWindowOpen(sc.carrier.Time_Zone__c);
            }

            interests.add(lci);
        }

        if (!interests.isEmpty()) insert interests;
    }

    // ─── Scoring ────────────────────────────────────────────────────────────

    private static Decimal computePriorityScore(Carrier__c c, String laneKey) {
        Decimal acceptanceRate = (c.Acceptance_Rate__c != null)    ? c.Acceptance_Rate__c    : 50;
        Decimal reputationScore = (c.Reputation_Score__c != null)  ? c.Reputation_Score__c  : 50;
        Decimal onTimeRate = (c.On_Time_Delivery_Rate__c != null)   ? c.On_Time_Delivery_Rate__c : 80;

        Decimal laneMatch = laneMatches(c, laneKey) ? 100 : 0;

        // Recency penalty: penalise carriers called in the last 24 hours
        Decimal recencyScore = 100;
        if (c.Last_Called__c != null) {
            Long hoursSinceLastCall = (DateTime.now().getTime() - c.Last_Called__c.getTime())
                                     / (1000 * 60 * 60);
            if (hoursSinceLastCall < 24) {
                recencyScore = Math.max(0, (Decimal) hoursSinceLastCall / 24 * 100);
            }
        }

        Decimal score = (acceptanceRate  * W_ACCEPTANCE)
                      + (reputationScore * W_REPUTATION)
                      + (onTimeRate      * W_ON_TIME)
                      + (laneMatch       * W_LANE_MATCH)
                      + (recencyScore    * W_RECENCY);

        if (c.Whitelisted__c) score += WHITELIST_BONUS;

        return score;
    }

    private static Boolean carriersEquipmentMatches(Carrier__c c, String requiredEquipment) {
        if (String.isBlank(c.Equipment_Types__c)) return false;
        List<String> types = c.Equipment_Types__c.split(';');
        for (String t : types) {
            if (t.trim().equalsIgnoreCase(requiredEquipment)) return true;
        }
        return false;
    }

    private static String getComplianceSkipReason(Carrier__c c) {
        if (c.FMCSA_Authority_Status__c != null
                && c.FMCSA_Authority_Status__c != 'Active'
                && c.FMCSA_Authority_Status__c != 'Unknown') {
            return 'FMCSA authority not active (' + c.FMCSA_Authority_Status__c + ')';
        }
        if (c.Insurance_Expiry__c != null && c.Insurance_Expiry__c < Date.today()) {
            return 'Insurance expired on ' + c.Insurance_Expiry__c.format();
        }
        if ('Unsatisfactory'.equalsIgnoreCase(c.Safety_Rating__c)) {
            return 'Safety rating: Unsatisfactory';
        }
        return null;
    }

    private static Boolean laneMatches(Carrier__c c, String laneKey) {
        if (String.isBlank(c.Preferred_Lanes__c)) return false;
        return c.Preferred_Lanes__c.containsIgnoreCase(laneKey)
            || c.Preferred_Lanes__c.containsIgnoreCase(
                   laneKey.substringBefore('-') + '→' + laneKey.substringAfter('-')
               );
    }

    // ─── Inner class ─────────────────────────────────────────────────────────

    private class ScoredCarrier implements Comparable {
        Carrier__c carrier;
        Decimal    score;
        String     skipReason;

        ScoredCarrier(Carrier__c c, Decimal s, String skip) {
            this.carrier    = c;
            this.score      = s;
            this.skipReason = skip;
        }

        public Integer compareTo(Object other) {
            ScoredCarrier o = (ScoredCarrier) other;
            // Skipped records sort to the bottom
            if (this.skipReason != null && o.skipReason == null) return 1;
            if (this.skipReason == null && o.skipReason != null) return -1;
            // Higher score = lower priority number (first to be called)
            if (this.score > o.score) return -1;
            if (this.score < o.score) return 1;
            return 0;
        }
    }
}
