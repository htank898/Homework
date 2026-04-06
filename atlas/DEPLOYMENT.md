# Atlas — Deployment Guide

## Prerequisites
- Salesforce DX CLI (`sf` or `sfdx`) installed
- Authorized org connection: `sf org login web --alias atlas-dev`
- API version 59.0 (Winter '24) or later

---

## Deploy to Org

```bash
# Deploy all Atlas metadata
sf project deploy start --source-dir atlas --target-org atlas-dev

# Or with legacy SFDX:
sfdx force:source:deploy -p atlas -u atlas-dev
```

---

## Post-Deployment Setup (required)

### 1. Configure Named Credentials
Go to **Setup → Named Credentials** and set the endpoint URLs and credentials for:

| Credential | Endpoint | Auth |
|---|---|---|
| `BlandAI` | `https://api.bland.ai` | Password = your Bland AI API key |
| `FMCSA_API` | `https://mobile.fmcsa.dot.gov` | None (key appended as query param) |
| `DAT_API` | `https://freight.api.dat.com` | OAuth2 or API key per DAT docs |
| `TMS_API` | Your TMS base URL | Per your TMS provider |

### 2. Configure BlandAI_Config__c Custom Setting
Go to **Setup → Custom Settings → Atlas Bland AI Config → Manage** and set:

| Field | Value |
|---|---|
| `Disclosure_Script__c` | "Hi, this is an automated call from [Your Brokerage]. I am an AI assistant..." |
| `Bland_Pathway_ID__c` | Your Bland AI pathway ID for freight outreach |
| `Webhook_URL__c` | `https://[your-org].my.salesforce.com/services/apexrest/atlas/bland/callback` |
| `Allow_Saturday_Calls__c` | false (or true if desired) |
| `Rate_API_Provider__c` | `DAT` or `Truckstop` |
| `Escalation_Rate_Threshold__c` | e.g. `5000` |

### 3. Activate Scheduled Jobs (run via Anonymous Apex)

```apex
// Schedule carrier reputation recalculation — nightly 2AM UTC
System.schedule('Atlas - Carrier Reputation Batch', '0 0 2 * * ?',
    new CarrierReputationBatchScheduler());

// Schedule call retry processor — every 5 minutes
CallRetryScheduler.scheduleEveryFiveMinutes();
```

### 4. Assign Permission Sets to Users
```bash
# Assign Atlas Agent to all freight broker users
sf data record create --sobject PermissionSetAssignment \
  --values "AssigneeId=[USER_ID] PermissionSetId=[ATLAS_AGENT_PS_ID]" \
  --target-org atlas-dev
```

Or via UI: Setup → Users → [User] → Permission Set Assignments → Edit Assignments

### 5. Add Remote Site Settings
Go to **Setup → Remote Site Settings** and add:
- `https://api.bland.ai`
- `https://mobile.fmcsa.dot.gov`
- `https://freight.api.dat.com` (or Truckstop equivalent)
- Your TMS base URL

### 6. Assign Atlas App to User Profiles
Setup → Apps → App Manager → Atlas → Edit → User Profiles → assign desired profiles.

---

## Testing Bland AI Webhook (Anonymous Apex)

```apex
// Simulate a 'interested' callback from Bland AI
// Replace IDs with real record IDs from your org
RestRequest req = new RestRequest();
req.requestURI = '/services/apexrest/atlas/bland/callback';
req.httpMethod = 'POST';
req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
    'call_id'       => 'TEST-001',
    'outcome'       => 'interested',
    'transcript'    => 'Yes, I can haul that load. What rate are you offering?',
    'recording_url' => 'https://example.com/recording.mp3',
    'duration'      => 90,
    'variables'     => new Map<String, Object>{
        'load_id'     => 'PASTE_LOAD_ID_HERE',
        'interest_id' => 'PASTE_INTEREST_ID_HERE',
        'carrier_id'  => 'PASTE_CARRIER_ID_HERE'
    }
}));
RestContext.request  = req;
RestContext.response = new RestResponse();
BlandCallbackController.handleCallback();
System.debug('Status: ' + RestContext.response.statusCode);
```

---

## Running Tests

```bash
# Run all Atlas test classes
sf apex run test --class-names BlandCallbackController_Test SelectCarriersForLoad_Test \
  --target-org atlas-dev --result-format human --wait 10
```

---

## Deactivate / Rollback

```bash
# Delete deployed components (use with caution on production)
sf project deploy start --source-dir atlas --target-org atlas-dev --destructive-changes
```
