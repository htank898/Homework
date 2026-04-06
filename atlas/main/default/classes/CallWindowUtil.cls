/**
 * CallWindowUtil
 * Timezone-aware call window enforcement.
 * Allowed calling window: Mon–Fri 08:00–18:00 in the carrier's local timezone.
 * Saturday support is controlled by BlandAI_Config__c.Allow_Saturday_Calls__c.
 */
public with sharing class CallWindowUtil {

    // Default window boundaries (local time, 24-hour)
    private static final Integer CALL_HOUR_START = 8;   // 08:00
    private static final Integer CALL_HOUR_END   = 18;  // 18:00

    /**
     * Returns true if the current moment falls within the allowed call window
     * for the given IANA timezone string (e.g. 'America/Chicago').
     */
    public static Boolean isWithinCallWindow(String ianaTimezone) {
        if (String.isBlank(ianaTimezone)) {
            ianaTimezone = 'America/Chicago'; // sensible default
        }

        TimeZone tz = TimeZone.getTimeZone(ianaTimezone);
        if (tz == null) {
            tz = TimeZone.getTimeZone('America/Chicago');
        }

        DateTime nowUtc = DateTime.now();
        // Convert UTC to local time by applying the timezone offset
        Integer offsetMs = tz.getOffset(nowUtc);
        DateTime localNow = nowUtc.addSeconds(offsetMs / 1000);

        Integer localHour    = localNow.hour();
        Integer localMinute  = localNow.minute();
        Integer dayOfWeek    = getDayOfWeek(localNow); // 1=Sun, 2=Mon, ... 7=Sat

        Boolean isSaturday = (dayOfWeek == 7);
        Boolean isSunday   = (dayOfWeek == 1);

        // Sunday is always blocked
        if (isSunday) return false;

        // Saturday requires explicit opt-in
        if (isSaturday) {
            BlandAI_Config__c cfg = BlandAI_Config__c.getOrgDefaults();
            if (cfg == null || !cfg.Allow_Saturday_Calls__c) return false;
        }

        // Check hour window (08:00–17:59 inclusive, i.e. last call starts before 18:00)
        if (localHour < CALL_HOUR_START) return false;
        if (localHour >= CALL_HOUR_END)  return false;

        return true;
    }

    /**
     * Given a carrier timezone, returns the next DateTime (UTC) when the call
     * window opens. Used to set Next_Retry_At__c when a call is deferred.
     */
    public static DateTime nextWindowOpen(String ianaTimezone) {
        if (String.isBlank(ianaTimezone)) {
            ianaTimezone = 'America/Chicago';
        }

        TimeZone tz = TimeZone.getTimeZone(ianaTimezone);
        if (tz == null) tz = TimeZone.getTimeZone('America/Chicago');

        DateTime nowUtc = DateTime.now();
        Integer offsetMs = tz.getOffset(nowUtc);
        DateTime localNow = nowUtc.addSeconds(offsetMs / 1000);

        // Start from the next day if we are past the window today
        DateTime candidate = DateTime.newInstance(
            localNow.date(), Time.newInstance(CALL_HOUR_START, 0, 0, 0)
        );
        if (localNow >= candidate) {
            candidate = candidate.addDays(1);
        }

        // Advance past Sunday (and optionally Saturday)
        BlandAI_Config__c cfg = BlandAI_Config__c.getOrgDefaults();
        Boolean allowSat = (cfg != null && cfg.Allow_Saturday_Calls__c);

        Integer safety = 0;
        while (safety < 10) {
            Integer dow = getDayOfWeek(candidate);
            if (dow == 1) { candidate = candidate.addDays(1); safety++; continue; } // Sunday
            if (dow == 7 && !allowSat) { candidate = candidate.addDays(1); safety++; continue; } // Saturday
            break;
        }

        // Convert back to UTC
        Integer offsetMs2 = tz.getOffset(candidate);
        return candidate.addSeconds(-offsetMs2 / 1000);
    }

    /**
     * Returns the day-of-week for a DateTime: 1=Sunday, 2=Monday, ... 7=Saturday.
     * Uses a known anchor: 2000-01-02 was a Sunday.
     */
    @TestVisible
    private static Integer getDayOfWeek(DateTime dt) {
        Date anchor = Date.newInstance(2000, 1, 2); // Sunday
        Long daysDiff = anchor.daysBetween(dt.date());
        Integer dow = (Integer)Math.mod(daysDiff, 7) + 1;
        if (dow <= 0) dow += 7;
        return dow;
    }
}
