/**
 * FMCSAService
 * Integrates with the FMCSA SAFER Web API to verify carrier authority,
 * insurance status, and safety scores.
 *
 * FMCSA SAFER API: https://mobile.fmcsa.dot.gov/qc/services/carriers/{dotNumber}
 * Uses Named Credential: FMCSA_API
 */
public with sharing class FMCSAService {

    private static final String FMCSA_NAMED_CREDENTIAL = 'callout:FMCSA_API';
    private static final String CARRIERS_ENDPOINT       = '/qc/services/carriers/';

    /**
     * Refreshes FMCSA compliance data for a single carrier.
     * Updates FMCSA_Authority_Status__c, Insurance_Expiry__c, Safety_Rating__c,
     * Out_Of_Service__c, and FMCSA_Last_Verified__c.
     *
     * @param carrierId  The Salesforce Id of the Carrier__c record
     */
    public static void refreshCarrier(Id carrierId) {
        Carrier__c carrier = [
            SELECT Id, DOT_Number__c, MC_Number__c, Compliance_Override__c
            FROM Carrier__c
            WHERE Id = :carrierId
            LIMIT 1
        ];

        if (String.isBlank(carrier.DOT_Number__c)) {
            System.debug('FMCSAService: Carrier ' + carrierId + ' has no DOT number, skipping.');
            return;
        }

        FMCSACarrierData data = callFMCSA(carrier.DOT_Number__c);
        if (data == null) return;

        applyDataToCarrier(carrier, data);
        update carrier;
    }

    /**
     * Batch-refreshes a list of carriers. Called from a scheduled Apex job.
     */
    @InvocableMethod(label='Refresh FMCSA Data for Carrier'
                     description='Calls FMCSA SAFER API to update compliance fields')
    public static void refreshCarriers(List<Id> carrierIds) {
        for (Id id : carrierIds) {
            refreshCarrier(id);
        }
    }

    // ─── Private helpers ────────────────────────────────────────────────────

    private static FMCSACarrierData callFMCSA(String dotNumber) {
        String endpoint = FMCSA_NAMED_CREDENTIAL + CARRIERS_ENDPOINT
            + EncodingUtil.urlEncode(dotNumber, 'UTF-8') + '?webKey=PLACEHOLDER';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(15000);

        try {
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) {
                System.debug('FMCSAService: HTTP ' + res.getStatusCode() + ' for DOT#' + dotNumber);
                return null;
            }
            return parseFMCSAResponse(res.getBody());
        } catch (Exception ex) {
            System.debug('FMCSAService: Exception — ' + ex.getMessage());
            return null;
        }
    }

    private static FMCSACarrierData parseFMCSAResponse(String body) {
        Map<String, Object> root   = (Map<String, Object>) JSON.deserializeUntyped(body);
        Map<String, Object> content = (Map<String, Object>) root.get('content');
        if (content == null) return null;
        Map<String, Object> carrier = (Map<String, Object>) content.get('carrier');
        if (carrier == null) return null;

        FMCSACarrierData data = new FMCSACarrierData();

        // Authority status
        String authStatus = (String) carrier.get('allowedToOperate');
        data.authorityStatus = ('Y'.equalsIgnoreCase(authStatus)) ? 'Active' : 'Inactive';

        // Safety rating
        data.safetyRating = mapSafetyRating((String) carrier.get('safetyRating'));

        // Out of service
        data.outOfService = 'Y'.equalsIgnoreCase((String) carrier.get('oosDate'));

        // Insurance (FMCSA SAFER returns insurance info in a nested list)
        // Parse insurance expiry from bipdInsuranceOnFile or cargo
        data.insuranceExpiry = parseInsuranceExpiry(carrier);

        return data;
    }

    private static String mapSafetyRating(String raw) {
        if (raw == null) return 'Unrated';
        if (raw.containsIgnoreCase('Satisfactory'))    return 'Satisfactory';
        if (raw.containsIgnoreCase('Conditional'))     return 'Conditional';
        if (raw.containsIgnoreCase('Unsatisfactory'))  return 'Unsatisfactory';
        return 'Unrated';
    }

    private static Date parseInsuranceExpiry(Map<String, Object> carrier) {
        // FMCSA returns insurance in bipdInsuranceOnFile — typically a date string
        String expiryStr = (String) carrier.get('bipdInsuranceRequired');
        if (String.isBlank(expiryStr)) return null;
        try {
            return Date.valueOf(expiryStr);
        } catch (Exception ex) {
            return null;
        }
    }

    private static void applyDataToCarrier(Carrier__c carrier, FMCSACarrierData data) {
        carrier.FMCSA_Authority_Status__c = data.authorityStatus;
        carrier.Safety_Rating__c          = data.safetyRating;
        carrier.Out_Of_Service__c         = data.outOfService;
        carrier.FMCSA_Last_Verified__c    = DateTime.now();

        if (data.insuranceExpiry != null) {
            carrier.Insurance_Expiry__c = data.insuranceExpiry;
        }

        // Auto-set Do Not Call if insurance expired or OOS (unless supervisor override)
        if (!carrier.Compliance_Override__c) {
            if (data.outOfService || data.authorityStatus == 'Inactive'
                    || data.authorityStatus == 'Revoked'
                    || (data.insuranceExpiry != null && data.insuranceExpiry < Date.today())) {
                carrier.Do_Not_Call__c = true;
            }
        }
    }

    // ─── Inner DTO ───────────────────────────────────────────────────────────

    private class FMCSACarrierData {
        String  authorityStatus;
        String  safetyRating;
        Boolean outOfService = false;
        Date    insuranceExpiry;
    }
}
