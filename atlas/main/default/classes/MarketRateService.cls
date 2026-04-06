/**
 * MarketRateService
 * Syncs spot market rates from DAT or Truckstop into Rate_Benchmark__c records.
 * Called by a scheduled Apex job every 4 hours.
 *
 * Named Credential: DAT_API  (configurable via BlandAI_Config__c.Rate_API_Provider__c)
 */
public with sharing class MarketRateService {

    private static final String DAT_CREDENTIAL        = 'callout:DAT_API';
    private static final String TRUCKSTOP_CREDENTIAL  = 'callout:Truckstop_API';
    private static final String DAT_RATES_ENDPOINT    = '/v1/rates/spot';

    /**
     * Fetches current market rate for a specific lane and equipment type.
     * Upserts the Rate_Benchmark__c record using Lane__c + Equipment_Type__c as the composite key.
     *
     * @param originState       Two-letter origin state (e.g. 'TX')
     * @param destinationState  Two-letter destination state (e.g. 'IL')
     * @param equipmentType     Equipment type string (must match picklist value)
     */
    public static void syncRate(String originState, String destinationState, String equipmentType) {
        String laneKey = originState.toUpperCase() + '-' + destinationState.toUpperCase();

        RateData data = fetchRateFromAPI(originState, destinationState, equipmentType);
        if (data == null) return;

        // Upsert the rate benchmark record
        Rate_Benchmark__c benchmark = new Rate_Benchmark__c(
            Name          = laneKey + ' ' + equipmentType,
            Lane__c       = laneKey,
            Equipment_Type__c = equipmentType,
            Low_Rate__c   = data.low,
            Average_Rate__c = data.avg,
            High_Rate__c  = data.high,
            Fuel_Surcharge__c = data.fsc,
            Source__c     = data.source,
            As_Of__c      = DateTime.now()
        );

        // Find existing record for this lane + equipment combo
        List<Rate_Benchmark__c> existing = [
            SELECT Id FROM Rate_Benchmark__c
            WHERE Lane__c = :laneKey
              AND Equipment_Type__c = :equipmentType
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            benchmark.Id = existing[0].Id;
        }

        upsert benchmark;
    }

    /**
     * Populates the Target_Rate__c on a Load record from the Rate_Benchmark__c.
     * Also returns the RateRange so the agent console can display low/avg/high.
     *
     * @param loadId  The Load__c record Id
     * @return        RateRange with low, avg, high fields (or null if no benchmark)
     */
    public static RateRange getRateRangeForLoad(Id loadId) {
        Load__c load = [
            SELECT Id, Origin_State__c, Destination_State__c, Equipment_Type__c
            FROM Load__c WHERE Id = :loadId LIMIT 1
        ];

        String laneKey = load.Origin_State__c.toUpperCase() + '-'
                       + load.Destination_State__c.toUpperCase();

        List<Rate_Benchmark__c> benchmarks = [
            SELECT Low_Rate__c, Average_Rate__c, High_Rate__c, Fuel_Surcharge__c, As_Of__c
            FROM Rate_Benchmark__c
            WHERE Lane__c = :laneKey
              AND Equipment_Type__c = :load.Equipment_Type__c
            ORDER BY As_Of__c DESC
            LIMIT 1
        ];

        if (benchmarks.isEmpty()) return null;
        Rate_Benchmark__c b = benchmarks[0];

        RateRange range = new RateRange();
        range.low  = b.Low_Rate__c;
        range.avg  = b.Average_Rate__c;
        range.high = b.High_Rate__c;
        range.fsc  = b.Fuel_Surcharge__c;
        return range;
    }

    /**
     * Invocable version — called from Load_Status_Change flow when a load is created
     * or origin/destination changes, to auto-populate Target_Rate__c.
     */
    @InvocableMethod(label='Set Target Rate from Market Benchmark'
                     description='Looks up Rate_Benchmark__c and sets Target_Rate__c on the load')
    public static void setTargetRateFromBenchmark(List<Id> loadIds) {
        List<Load__c> toUpdate = new List<Load__c>();

        for (Id loadId : loadIds) {
            RateRange range = getRateRangeForLoad(loadId);
            if (range != null && range.avg != null) {
                toUpdate.add(new Load__c(Id = loadId, Target_Rate__c = range.avg));
            }
        }

        if (!toUpdate.isEmpty()) update toUpdate;
    }

    // ─── Private helpers ────────────────────────────────────────────────────

    private static RateData fetchRateFromAPI(String originState, String destState, String equipType) {
        // Determine which provider to use
        BlandAI_Config__c cfg = BlandAI_Config__c.getOrgDefaults();
        String provider = (cfg != null && String.isNotBlank(cfg.Rate_API_Provider__c))
            ? cfg.Rate_API_Provider__c : 'DAT';

        String credential = (provider == 'Truckstop') ? TRUCKSTOP_CREDENTIAL : DAT_CREDENTIAL;

        Map<String, Object> requestPayload = new Map<String, Object>{
            'origin'      => new Map<String, Object>{ 'stateProv' => originState },
            'destination' => new Map<String, Object>{ 'stateProv' => destState },
            'equipment'   => equipType
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(credential + DAT_RATES_ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(requestPayload));
        req.setTimeout(10000);

        try {
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) {
                System.debug('MarketRateService: HTTP ' + res.getStatusCode());
                return null;
            }
            return parseRateResponse(res.getBody(), provider);
        } catch (Exception ex) {
            System.debug('MarketRateService: Exception — ' + ex.getMessage());
            return null;
        }
    }

    private static RateData parseRateResponse(String body, String provider) {
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(body);
        RateData data = new RateData();
        data.source = provider;

        try {
            // DAT response shape: { "ratePerMile": { "low": 2.10, "average": 2.45, "high": 2.80 },
            //                       "fuelSurcharge": 0.42 }
            Map<String, Object> rpm = (Map<String, Object>) root.get('ratePerMile');
            if (rpm != null) {
                data.low  = (Decimal) rpm.get('low');
                data.avg  = (Decimal) rpm.get('average');
                data.high = (Decimal) rpm.get('high');
            }
            data.fsc = (Decimal) root.get('fuelSurcharge');
        } catch (Exception ex) {
            System.debug('MarketRateService: Parse error — ' + ex.getMessage());
            return null;
        }

        return data;
    }

    // ─── Inner DTOs ──────────────────────────────────────────────────────────

    private class RateData {
        Decimal low;
        Decimal avg;
        Decimal high;
        Decimal fsc;
        String  source;
    }

    public class RateRange {
        @AuraEnabled public Decimal low  { get; set; }
        @AuraEnabled public Decimal avg  { get; set; }
        @AuraEnabled public Decimal high { get; set; }
        @AuraEnabled public Decimal fsc  { get; set; }
    }
}
