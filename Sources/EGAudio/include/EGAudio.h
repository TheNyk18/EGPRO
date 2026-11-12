#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Numarul de benzi ale egalizatorului (32 Hz ... 16 kHz).
#define EG_BAND_COUNT 10

/// Trimisa (pe firul principal) cand motorul porneste, se opreste sau schimba iesirea audio.
extern NSString * const EGEngineDidChangeNotification;

/// YES daca sistemul permite captarea sunetului (macOS 14.2 sau mai nou).
BOOL EGEngineIsSupported(void);

/// Porneste egalizatorul. Intoarce nil daca a mers, altfel un mesaj de eroare in romana.
NSString * _Nullable EGEngineStart(void);

/// Opreste egalizatorul; sunetul revine la normal.
void EGEngineStop(void);

/// YES daca egalizatorul ruleaza acum.
BOOL EGEngineIsRunning(void);

/// Numele dispozitivului pe care se aude sunetul (ex. "MacBook Pro Speakers").
NSString *EGEngineOutputDeviceName(void);

/// Seteaza castigul fiecarei benzi (in dB, -12...+12) si pre-amplificarea (in dB).
void EGEngineSetBands(const float *gainsDB, int count, float preampDB);

NS_ASSUME_NONNULL_END
