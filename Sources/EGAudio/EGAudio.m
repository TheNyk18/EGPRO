// EGPRO - motorul audio.
//
// Cum functioneaza:
//  1. Facem un "tap" (macOS 14.2+) care ia sunetul tuturor aplicatiilor (in afara de EGPRO)
//     si il opreste sa mai ajunga direct la boxe ("muted when tapped").
//  2. Facem un dispozitiv agregat privat care contine tap-ul (intrare) si boxele/castile (iesire).
//  3. In functia audio (IOProc) trecem sunetul prin 10 filtre (egalizator) si il trimitem la iesire.
//  4. Cand opresti EGPRO (sau daca se inchide), tap-ul dispare si sunetul revine la normal.

#import "EGAudio.h"
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdatomic.h>
#include <unistd.h>

NSString * const EGEngineDidChangeNotification = @"EGEngineDidChangeNotification";

#pragma mark - Egalizator (filtre biquad "peaking", formulele RBJ)

static const double kBandFreqs[EG_BAND_COUNT] = {
    32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0
};
static const double kBandQ = 1.41; // aproximativ o octava pe banda

typedef struct {
    double b0, b1, b2, a1, a2;
} EGCoef;

// Doua seturi de coeficienti: UI-ul scrie in cel inactiv, apoi il activeaza atomic.
static EGCoef gCoefs[2][EG_BAND_COUNT];
static double gPreampLinear[2] = {1.0, 1.0};
static _Atomic int gActiveCoefs = 0;

// Starea filtrelor: [canal][banda][z1, z2]
static double gState[2][EG_BAND_COUNT][2];

static float gGainsDB[EG_BAND_COUNT];
static float gPreampDB = 0.0f;
static double gSampleRate = 48000.0;

static void EGComputeCoefs(EGCoef *out, double freq, double gainDB, double fs) {
    if (fabs(gainDB) < 0.01 || freq >= fs * 0.45 || fs <= 0) {
        out->b0 = 1.0; out->b1 = 0.0; out->b2 = 0.0; out->a1 = 0.0; out->a2 = 0.0;
        return;
    }
    double A = pow(10.0, gainDB / 40.0);
    double w0 = 2.0 * M_PI * freq / fs;
    double cw = cos(w0);
    double alpha = sin(w0) / (2.0 * kBandQ);
    double a0 = 1.0 + alpha / A;
    out->b0 = (1.0 + alpha * A) / a0;
    out->b1 = (-2.0 * cw) / a0;
    out->b2 = (1.0 - alpha * A) / a0;
    out->a1 = (-2.0 * cw) / a0;
    out->a2 = (1.0 - alpha / A) / a0;
}

static void EGRebuildCoefs(void) {
    int next = 1 - atomic_load(&gActiveCoefs);
    for (int b = 0; b < EG_BAND_COUNT; b++) {
        EGComputeCoefs(&gCoefs[next][b], kBandFreqs[b], gGainsDB[b], gSampleRate);
    }
    gPreampLinear[next] = pow(10.0, gPreampDB / 20.0);
    atomic_store(&gActiveCoefs, next);
}

static void EGResetState(void) {
    memset(gState, 0, sizeof(gState));
}

static inline float EGProcessSample(float in, int ch, const EGCoef *coefs, double preamp) {
    double x = (double)in * preamp;
    for (int b = 0; b < EG_BAND_COUNT; b++) {
        const EGCoef *c = &coefs[b];
        double *z = gState[ch][b];
        double y = c->b0 * x + z[0];
        z[0] = c->b1 * x - c->a1 * y + z[1];
        z[1] = c->b2 * x - c->a2 * y;
        x = y;
    }
    if (!isfinite(x)) {
        memset(gState[ch], 0, sizeof(gState[ch]));
        return 0.0f;
    }
    return (float)x;
}

#pragma mark - Stare motor

static AudioObjectID gTapID = kAudioObjectUnknown;
static AudioObjectID gAggregateID = kAudioObjectUnknown;
static AudioDeviceIOProcID gProcID = NULL;
static BOOL gRunning = NO;
static BOOL gWantRunning = NO;
static BOOL gListenerInstalled = NO;
static NSString *gOutputName = @"";

// Formatul tap-ului (ca sa stim cum citim canalele)
static UInt32 gTapChannels = 2;
static BOOL gTapNonInterleaved = NO;

#pragma mark - Functia audio (ruleaza in timp real)

static OSStatus EGIOProc(AudioObjectID inDevice,
                         const AudioTimeStamp *inNow,
                         const AudioBufferList *inInputData,
                         const AudioTimeStamp *inInputTime,
                         AudioBufferList *outOutputData,
                         const AudioTimeStamp *inOutputTime,
                         void *inClientData) {
    if (outOutputData == NULL || outOutputData->mNumberBuffers == 0) return noErr;

    // Liniste in toate iesirile, apoi scriem doar stanga/dreapta.
    for (UInt32 i = 0; i < outOutputData->mNumberBuffers; i++) {
        if (outOutputData->mBuffers[i].mData) {
            memset(outOutputData->mBuffers[i].mData, 0, outOutputData->mBuffers[i].mDataByteSize);
        }
    }
    if (inInputData == NULL || inInputData->mNumberBuffers == 0) return noErr;

    // Tap-ul e mereu la sfarsitul intrarilor (inaintea lui pot fi microfoane ale dispozitivului).
    const float *inL = NULL, *inR = NULL;
    UInt32 inStride = 1, inFrames = 0;
    UInt32 nIn = inInputData->mNumberBuffers;
    if (gTapNonInterleaved && gTapChannels >= 2 && nIn >= 2) {
        const AudioBuffer *bl = &inInputData->mBuffers[nIn - 2];
        const AudioBuffer *br = &inInputData->mBuffers[nIn - 1];
        inL = (const float *)bl->mData;
        inR = (const float *)br->mData;
        inStride = 1;
        inFrames = bl->mDataByteSize / sizeof(float);
        UInt32 fr = br->mDataByteSize / sizeof(float);
        if (fr < inFrames) inFrames = fr;
    } else {
        const AudioBuffer *b = &inInputData->mBuffers[nIn - 1];
        UInt32 ch = b->mNumberChannels > 0 ? b->mNumberChannels : 1;
        inL = (const float *)b->mData;
        inR = ch > 1 ? inL + 1 : inL;
        inStride = ch;
        inFrames = b->mDataByteSize / (sizeof(float) * ch);
    }
    if (inL == NULL || inR == NULL) return noErr;

    // Iesirea: fie un buffer cu canale intercalate, fie cate un buffer pe canal.
    float *outL = NULL, *outR = NULL;
    UInt32 outStride = 1, outFrames = 0;
    AudioBuffer *ob0 = &outOutputData->mBuffers[0];
    if (ob0->mNumberChannels >= 2 || outOutputData->mNumberBuffers == 1) {
        UInt32 ch = ob0->mNumberChannels > 0 ? ob0->mNumberChannels : 1;
        outL = (float *)ob0->mData;
        outR = ch > 1 ? outL + 1 : NULL;
        outStride = ch;
        outFrames = ob0->mDataByteSize / (sizeof(float) * ch);
    } else {
        AudioBuffer *ob1 = &outOutputData->mBuffers[1];
        outL = (float *)ob0->mData;
        outR = (float *)ob1->mData;
        outStride = 1;
        outFrames = ob0->mDataByteSize / sizeof(float);
        UInt32 fr = ob1->mDataByteSize / sizeof(float);
        if (fr < outFrames) outFrames = fr;
    }
    if (outL == NULL) return noErr;

    UInt32 frames = inFrames < outFrames ? inFrames : outFrames;
    int idx = atomic_load(&gActiveCoefs);
    const EGCoef *coefs = gCoefs[idx];
    double preamp = gPreampLinear[idx];

    for (UInt32 f = 0; f < frames; f++) {
        float l = inL[f * inStride];
        float r = inR[f * inStride];
        l = EGProcessSample(l, 0, coefs, preamp);
        r = EGProcessSample(r, 1, coefs, preamp);
        if (outR) {
            outL[f * outStride] = l;
            outR[f * outStride] = r;
        } else {
            outL[f * outStride] = 0.5f * (l + r); // iesire mono
        }
    }
    return noErr;
}

#pragma mark - Ajutoare Core Audio

static AudioObjectPropertyAddress EGAddr(AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress a = { sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    return a;
}

static AudioObjectID EGDefaultOutputDevice(void) {
    AudioObjectPropertyAddress a = EGAddr(kAudioHardwarePropertyDefaultOutputDevice);
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(dev);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &dev) != noErr) {
        return kAudioObjectUnknown;
    }
    return dev;
}

static NSString *EGStringProperty(AudioObjectID obj, AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress a = EGAddr(sel);
    CFStringRef str = NULL;
    UInt32 size = sizeof(str);
    if (AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, &str) != noErr || str == NULL) {
        return nil;
    }
    return (NSString *)CFBridgingRelease(str);
}

static AudioObjectID EGOwnProcessObject(void) {
    AudioObjectPropertyAddress a = EGAddr(kAudioHardwarePropertyTranslatePIDToProcessObject);
    pid_t pid = getpid();
    AudioObjectID obj = kAudioObjectUnknown;
    UInt32 size = sizeof(obj);
    OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(pid), &pid, &size, &obj);
    if (st != noErr) return kAudioObjectUnknown;
    return obj;
}

static NSString *EGErr(NSString *what, OSStatus st) {
    return [NSString stringWithFormat:@"%@ (cod %d)", what, (int)st];
}

static void EGPostChange(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:EGEngineDidChangeNotification object:nil];
    });
}

#pragma mark - Pornire / oprire

static void EGTeardown(void) {
    if (gAggregateID != kAudioObjectUnknown && gProcID != NULL) {
        AudioDeviceStop(gAggregateID, gProcID);
        AudioDeviceDestroyIOProcID(gAggregateID, gProcID);
    }
    gProcID = NULL;
    if (gAggregateID != kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(gAggregateID);
        gAggregateID = kAudioObjectUnknown;
    }
    if (gTapID != kAudioObjectUnknown) {
        if (@available(macOS 14.2, *)) {
            AudioHardwareDestroyProcessTap(gTapID);
        }
        gTapID = kAudioObjectUnknown;
    }
    gRunning = NO;
}

API_AVAILABLE(macos(14.2))
static NSString *EGSetup(void) {
    OSStatus st;

    // 1. Iesirea curenta (boxe / casti)
    AudioObjectID outDev = EGDefaultOutputDevice();
    if (outDev == kAudioObjectUnknown) {
        return @"Nu am gasit nicio iesire audio (boxe sau casti).";
    }
    NSString *outUID = EGStringProperty(outDev, kAudioDevicePropertyDeviceUID);
    if (outUID == nil) {
        return @"Nu pot citi iesirea audio.";
    }
    NSString *name = EGStringProperty(outDev, kAudioObjectPropertyName);
    gOutputName = name ?: @"";

    // 2. Tap pe tot sunetul Mac-ului, in afara de EGPRO (altfel s-ar auzi de doua ori / ecou)
    AudioObjectID selfObj = EGOwnProcessObject();
    NSArray<NSNumber *> *exclude = (selfObj != kAudioObjectUnknown) ? @[ @(selfObj) ] : @[];
    CATapDescription *tapDesc = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:exclude];
    tapDesc.name = @"EGPRO";
    tapDesc.privateTap = YES;
    tapDesc.muteBehavior = CATapMutedWhenTapped; // sunetul original e oprit doar cat timp il luam noi

    AudioObjectID tapID = kAudioObjectUnknown;
    st = AudioHardwareCreateProcessTap(tapDesc, &tapID);
    if (st != noErr || tapID == kAudioObjectUnknown) {
        return EGErr(@"Nu am putut lua sunetul Mac-ului. Verifica permisiunea in System Settings > Privacy & Security", st);
    }
    gTapID = tapID;
    NSString *tapUID = tapDesc.UUID.UUIDString;

    // Formatul tap-ului
    AudioStreamBasicDescription tapFormat;
    memset(&tapFormat, 0, sizeof(tapFormat));
    UInt32 size = sizeof(tapFormat);
    AudioObjectPropertyAddress fa = EGAddr(kAudioTapPropertyFormat);
    if (AudioObjectGetPropertyData(gTapID, &fa, 0, NULL, &size, &tapFormat) == noErr) {
        gTapChannels = tapFormat.mChannelsPerFrame > 0 ? tapFormat.mChannelsPerFrame : 2;
        gTapNonInterleaved = (tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    } else {
        gTapChannels = 2;
        gTapNonInterleaved = NO;
    }

    // 3. Dispozitiv agregat privat: tap-ul + iesirea
    NSDictionary *aggDesc = @{
        @kAudioAggregateDeviceNameKey: @"EGPRO",
        @kAudioAggregateDeviceUIDKey: [[NSUUID UUID] UUIDString],
        @kAudioAggregateDeviceMainSubDeviceKey: outUID,
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceIsStackedKey: @NO,
        @kAudioAggregateDeviceTapAutoStartKey: @YES,
        @kAudioAggregateDeviceSubDeviceListKey: @[ @{ @kAudioSubDeviceUIDKey: outUID } ],
        @kAudioAggregateDeviceTapListKey: @[ @{
            @kAudioSubTapDriftCompensationKey: @YES,
            @kAudioSubTapUIDKey: tapUID,
        } ],
    };
    AudioObjectID aggID = kAudioObjectUnknown;
    st = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggDesc, &aggID);
    if (st != noErr || aggID == kAudioObjectUnknown) {
        return EGErr(@"Nu am putut pregati iesirea audio", st);
    }
    gAggregateID = aggID;

    // Frecventa de esantionare (pentru filtre)
    Float64 rate = 0;
    size = sizeof(rate);
    AudioObjectPropertyAddress ra = EGAddr(kAudioDevicePropertyNominalSampleRate);
    if (AudioObjectGetPropertyData(gAggregateID, &ra, 0, NULL, &size, &rate) == noErr && rate > 0) {
        gSampleRate = rate;
    } else if (tapFormat.mSampleRate > 0) {
        gSampleRate = tapFormat.mSampleRate;
    }
    EGResetState();
    EGRebuildCoefs();

    // 4. Pornim functia audio
    st = AudioDeviceCreateIOProcID(gAggregateID, EGIOProc, NULL, &gProcID);
    if (st != noErr || gProcID == NULL) {
        return EGErr(@"Nu am putut porni procesarea sunetului", st);
    }
    st = AudioDeviceStart(gAggregateID, gProcID);
    if (st != noErr) {
        return EGErr(@"Nu am putut porni sunetul", st);
    }
    gRunning = YES;
    return nil;
}

static NSString *EGStartInternal(void) {
    if (@available(macOS 14.2, *)) {
        EGTeardown();
        NSString *err = EGSetup();
        if (err != nil) {
            EGTeardown();
        }
        return err;
    }
    return @"EGPRO are nevoie de macOS 14.2 sau mai nou.";
}

// Cand schimbi iesirea (ex. conectezi castile), repornim pe noua iesire.
static void EGInstallListener(void) {
    if (gListenerInstalled) return;
    gListenerInstalled = YES;
    AudioObjectPropertyAddress a = EGAddr(kAudioHardwarePropertyDefaultOutputDevice);
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &a, dispatch_get_main_queue(),
        ^(UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses) {
            if (!gWantRunning) return;
            // mica pauza ca noua iesire sa fie gata
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                if (!gWantRunning) return;
                EGStartInternal();
                EGPostChange();
            });
        });
}

#pragma mark - API public

BOOL EGEngineIsSupported(void) {
    if (@available(macOS 14.2, *)) {
        return YES;
    }
    return NO;
}

NSString *EGEngineStart(void) {
    gWantRunning = YES;
    EGInstallListener();
    NSString *err = EGStartInternal();
    if (err != nil) {
        gWantRunning = NO;
    }
    EGPostChange();
    return err;
}

void EGEngineStop(void) {
    gWantRunning = NO;
    EGTeardown();
    EGPostChange();
}

BOOL EGEngineIsRunning(void) {
    return gRunning;
}

NSString *EGEngineOutputDeviceName(void) {
    return gOutputName ?: @"";
}

void EGEngineSetBands(const float *gainsDB, int count, float preampDB) {
    for (int i = 0; i < EG_BAND_COUNT; i++) {
        float g = (i < count && gainsDB != NULL) ? gainsDB[i] : 0.0f;
        if (g > 12.0f) g = 12.0f;
        if (g < -12.0f) g = -12.0f;
        gGainsDB[i] = g;
    }
    gPreampDB = preampDB;
    EGRebuildCoefs();
}
