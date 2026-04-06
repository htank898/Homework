/**
 * TMSIntegrationService
 * Pushes confirmed loads to an external Transportation Management System (TMS)
 * via REST API. Uses Named Credential: TMS_API.
 *
 * Called automatically from the Booking_Confirmation_Flow when a load is Booked.
 * Supports retry via Task creation on failure.
 */
public with sharing class TMSIntegrationService {

    private static final String TMS_NAMED_CREDENTIAL = 'callout:TMS_API';
    private static final String TMS_LOADS_ENDPOINT   = '/api/v1/loads';

    /**
     * Pushes a confirmed load to the TMS. Updates Rate_Confirmation__c.TMS_Push_Status__c.
     *
     * @param rateConfirmationId  The Rate_Confirmation__c record Id
     */
    public static void pushLoadToTMS(Id rateConfirmationId) {
        Rate_Confirmation__c rc = [
            SELECT Id, Load__c, Carrier__c, Agreed_Rate__c, TMS_Push_Status__c,
                   Load__r.Name, Load__r.Origin_City__c, Load__r.Origin_State__c,
                   Load__r.Origin_Zip__c, Load__r.Destination_City__c,
                   Load__r.Destination_State__c, Load__r.Destination_Zip__c,
                   Load__r.Pickup_Date__c, Load__r.Delivery_Date__c,
                   Load__r.Equipment_Type__c, Load__r.Commodity__c, Load__r.Weight_lbs__c,
                   Load__r.External_ID__c,
                   Carrier__r.Name, Carrier__r.MC_Number__c, Carrier__r.DOT_Number__c,
                   Carrier__r.Contact_Phone__c, Carrier__r.Email__c
            FROM Rate_Confirmation__c
            WHERE Id = :rateConfirmationId
            LIMIT 1
        ];

        if (rc.TMS_Push_Status__c == 'Sent') return; // Already pushed

        Map<String, Object> payload = buildPayload(rc);

        HttpRequest req = new HttpRequest();
        req.setEndpoint(TMS_NAMED_CREDENTIAL + TMS_LOADS_ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(payload));
        req.setTimeout(15000);

        try {
            HttpResponse res = new Http().send(req);

            if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
                Map<String, Object> responseBody =
                    (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                String tmsLoadId = (String) responseBody.get('id');

                update new Rate_Confirmation__c(
                    Id                 = rc.Id,
                    TMS_Push_Status__c = 'Sent',
                    TMS_Load_ID__c     = tmsLoadId
                );

                System.debug('TMSIntegrationService: Load pushed. TMS ID=' + tmsLoadId);

            } else {
                markFailed(rc.Id, rc.Load__c);
                System.debug('TMSIntegrationService: Push failed. HTTP '
                    + res.getStatusCode() + ' — ' + res.getBody());
            }

        } catch (Exception ex) {
            markFailed(rc.Id, rc.Load__c);
            System.debug('TMSIntegrationService: Exception — ' + ex.getMessage());
        }
    }

    @InvocableMethod(label='Push Load to TMS'
                     description='Sends confirmed load data to the TMS via REST API')
    public static void pushLoadsToTMS(List<Id> rateConfirmationIds) {
        for (Id id : rateConfirmationIds) {
            pushLoadToTMS(id);
        }
    }

    // ─── Private helpers ────────────────────────────────────────────────────

    private static Map<String, Object> buildPayload(Rate_Confirmation__c rc) {
        return new Map<String, Object>{
            'external_reference' => rc.Load__r.Name,
            'origin' => new Map<String, Object>{
                'city'    => rc.Load__r.Origin_City__c,
                'state'   => rc.Load__r.Origin_State__c,
                'zip'     => rc.Load__r.Origin_Zip__c
            },
            'destination' => new Map<String, Object>{
                'city'    => rc.Load__r.Destination_City__c,
                'state'   => rc.Load__r.Destination_State__c,
                'zip'     => rc.Load__r.Destination_Zip__c
            },
            'pickup_date'     => rc.Load__r.Pickup_Date__c,
            'delivery_date'   => rc.Load__r.Delivery_Date__c,
            'equipment_type'  => rc.Load__r.Equipment_Type__c,
            'commodity'       => rc.Load__r.Commodity__c,
            'weight_lbs'      => rc.Load__r.Weight_lbs__c,
            'agreed_rate'     => rc.Agreed_Rate__c,
            'carrier' => new Map<String, Object>{
                'name'      => rc.Carrier__r.Name,
                'mc_number' => rc.Carrier__r.MC_Number__c,
                'dot_number'=> rc.Carrier__r.DOT_Number__c,
                'phone'     => rc.Carrier__r.Contact_Phone__c,
                'email'     => rc.Carrier__r.Email__c
            },
            'rate_confirmation_id' => rc.Id
        };
    }

    private static void markFailed(Id rcId, Id loadId) {
        update new Rate_Confirmation__c(Id = rcId, TMS_Push_Status__c = 'Failed');

        // Create a Task for the agent to manually push or investigate
        insert new Task(
            WhatId  = loadId,
            Subject = 'TMS Push Failed — Manual Action Required',
            Status  = 'Open',
            Priority = 'High',
            ActivityDate = Date.today()
        );
    }
}
