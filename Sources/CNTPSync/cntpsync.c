#include "cntpsync.h"

#include <sys/time.h>
#include <sys/timex.h>

bool ntpserver_clock_synced(void) {
    struct timex tx;
    tx.modes = 0;                 // nur lesen, nichts verstellen
    int r = ntp_adjtime(&tx);
    if (r < 0) return false;      // Aufruf fehlgeschlagen
    if (r == TIME_ERROR) return false;        // Kernel meldet "unsynchronisiert"
    if (tx.status & STA_UNSYNC) return false; // Sync-Bit explizit nicht gesetzt
    return true;
}
