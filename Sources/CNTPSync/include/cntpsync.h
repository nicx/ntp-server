#ifndef CNTPSYNC_H
#define CNTPSYNC_H

#include <stdbool.h>

// Liefert true, wenn die macOS-Systemuhr aktuell synchronisiert ist
// (Kernel-NTP-Status via ntp_adjtime, STA_UNSYNC nicht gesetzt).
// Dient dazu, im NTP-Paket ehrlich Stratum/LI abzuleiten, statt blind
// "synchronisiert" zu behaupten.
bool ntpserver_clock_synced(void);

#endif /* CNTPSYNC_H */
