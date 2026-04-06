/**
 * BlandOutboundService
 * Initiates outbound calls through the Bland AI REST API.
 * Uses the BlandAI Named Credential for authentication.
 *
 * Bland AI docs reference: POST /v1/calls
 */
public with sharing class BlandOutboundService {

    private static final String BLAND_NAMED_CREDENTIAL = 'callout:BlandAI';
    private static final String CALLS_ENDPOINT         = '/v1/calls';

    /**
     * Initiates an outbound call for a single Load_Carrier_Interest__c record.
     * Creates a Call_Log__c record and sets the Bland call ID on it.
     *
     * @param interest  The Load_Carrier_Interest__c record (with Load__r and Carrier__r populated)
     * @return          The Bland call ID, or null on failure
     */
    public static String initiateCall(Load_Carrier_Interest__c interest) {
        Load__c load         = interest.Load__r;
        Carrier__c carrier   = interest.Carrier__r;

        // Enforce call window before dialing
        if (!CallWindowUtil.isWithinCallWindow(carrier.Time_Zone__c)) {
            DateTime nextWindow = CallWindowUtil.nextWindowOpen(carrier.Time_Zone__c);
            interest.Status__c       = 'Retry Pending';
            interest.Next_Retry_At__c = nextWindow;
            update interest;
            return null;
        }

        // Pull config for disclosure script and rate to quote
        BlandAI_Config__c cfg = BlandAI_Config__c.getOrgDefaults();
        String disclosureScript = (cfg != null && String.isNotBlank(cfg.Disclosure_Script__c))
            ? cfg.Disclosure_Script__c
            : 'This is an automated call from Atlas Freight. I am an AI assistant.';

        // Build dynamic variables for the Bland AI pathway
        Map<String, Object> variables = new Map<String, Object>{
            'load_id'            => load.Id,
            'load_name'          => load.Name,
            'origin_city'        => load.Origin_City__c,
            'origin_state'       => load.Origin_State__c,
            'destination_city'   => load.Destination_City__c,
            'destination_state'  => load.Destination_State__c,
            'pickup_date'        => load.Pickup_Date__c != null
                                        ? load.Pickup_Date__c.format('MM/dd/yyyy', 'America/Chicago')
                                        : '',
            'equipment_type'     => load.Equipment_Type__c,
            'target_rate'        => load.Target_Rate__c != null
                                        ? String.valueOf(load.Target_Rate__c)
                                        : '',
            'carrier_name'       => carrier.Name,
            'disclosure_script'  => disclosureScript
        };

        // Build the Bland API payload
        Map<String, Object> payload = new Map<String, Object>{
            'phone_number'  => carrier.Contact_Phone__c,
            'task'          => 'freight_outreach',
            'pathway_id'    => cfg != null ? cfg.Bland_Pathway_ID__c : null,
            'voice'         => 'maya',
            'language'      => 'en-US',
            'request_data'  => variables,
            'webhook'       => cfg != null ? cfg.Webhook_URL__c : null,
            'metadata'      => new Map<String, Object>{
                'load_id'      => load.Id,
                'interest_id'  => interest.Id,
                'carrier_id'   => carrier.Id
            }
        };

        String requestBody = JSON.serialize(payload);

        HttpRequest req = new HttpRequest();
        req.setEndpoint(BLAND_NAMED_CREDENTIAL + CALLS_ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(requestBody);
        req.setTimeout(10000);

        Http http = new Http();
        String blandCallId = null;

        try {
            HttpResponse res = http.send(req);

            if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
                Map<String, Object> responseBody =
                    (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                blandCallId = (String) responseBody.get('call_id');

                // Create Call Log
                Call_Log__c log = new Call_Log__c(
                    Load__c      = load.Id,
                    Carrier__c   = carrier.Id,
                    Called_At__c = DateTime.now(),
                    Bland_Call_ID__c = blandCallId,
                    Outcome__c   = 'Pending',
                    Rate_Quoted__c = load.Target_Rate__c
                );
                insert log;

                // Update interest record
                interest.Status__c       = 'Called';
                interest.Retry_Count__c  = (interest.Retry_Count__c == null ? 0 : interest.Retry_Count__c) + 1;
                update interest;

                // Update carrier's last called date
                update new Carrier__c(Id = carrier.Id, Last_Called__c = DateTime.now());

            } else {
                System.debug('BlandOutboundService: Call failed. Status=' + res.getStatusCode()
                    + ' Body=' + res.getBody());
            }

        } catch (Exception ex) {
            System.debug('BlandOutboundService: Exception — ' + ex.getMessage());
        }

        return blandCallId;
    }

    /**
     * Batch-initiates calls for all Queued records on a load.
     * Called from the Load_Status_Change flow via Invocable method.
     */
    @InvocableMethod(label='Initiate Bland AI Calls for Load'
                     description='Starts outbound AI calls for all queued carriers on a load')
    public static void initiateCallsForLoad(List<Id> loadIds) {
        for (Id loadId : loadIds) {
            initiateCallsForLoadInternal(loadId);
        }
    }

    private static void initiateCallsForLoadInternal(Id loadId) {
        // First, run carrier selection if queue is empty
        List<Load_Carrier_Interest__c> queue = [
            SELECT Id, Status__c, Priority__c, Retry_Count__c, Next_Retry_At__c,
                   Load__r.Id, Load__r.Name, Load__r.Origin_City__c, Load__r.Origin_State__c,
                   Load__r.Destination_City__c, Load__r.Destination_State__c,
                   Load__r.Pickup_Date__c, Load__r.Equipment_Type__c, Load__r.Target_Rate__c,
                   Carrier__r.Id, Carrier__r.Name, Carrier__r.Contact_Phone__c,
                   Carrier__r.Time_Zone__c, Carrier__r.Last_Called__c
            FROM Load_Carrier_Interest__c
            WHERE Load__c = :loadId
              AND Status__c = 'Queued'
            ORDER BY Priority__c ASC
            LIMIT 10
        ];

        if (queue.isEmpty()) {
            // Build the queue first
            SelectCarriersForLoad.selectAndQueue(loadId);
            queue = [
                SELECT Id, Status__c, Priority__c, Retry_Count__c, Next_Retry_At__c,
                       Load__r.Id, Load__r.Name, Load__r.Origin_City__c, Load__r.Origin_State__c,
                       Load__r.Destination_City__c, Load__r.Destination_State__c,
                       Load__r.Pickup_Date__c, Load__r.Equipment_Type__c, Load__r.Target_Rate__c,
                       Carrier__r.Id, Carrier__r.Name, Carrier__r.Contact_Phone__c,
                       Carrier__r.Time_Zone__c, Carrier__r.Last_Called__c
                FROM Load_Carrier_Interest__c
                WHERE Load__c = :loadId
                  AND Status__c = 'Queued'
                ORDER BY Priority__c ASC
                LIMIT 10
            ];
        }

        for (Load_Carrier_Interest__c interest : queue) {
            initiateCall(interest);
        }
    }
}
