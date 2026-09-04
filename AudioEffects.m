#import "VBYAudio.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <AudioUnit/AudioUnitParameters.h>
#import <os/lock.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "fishhook.h"

#define VBY_MAX_CHANNELS 8
#define VBY_EQ_BANDS 5

typedef struct {
  float b0;
  float b1;
  float b2;
  float a1;
  float a2;
  float z1[VBY_MAX_CHANNELS];
  float z2[VBY_MAX_CHANNELS];
} VBYBiquad;

typedef struct {
  AudioStreamBasicDescription format;
  uint32_t generation;
  VBYBiquad bands[VBY_EQ_BANDS];
} VBYEQState;

typedef struct VBYRenderContext {
  AudioUnit outputUnit;
  AudioUnitElement element;
  AURenderCallback originalProc;
  void *originalRefCon;
  AudioStreamBasicDescription format;
  volatile BOOL hasFormat;
  AudioUnit pitchUnit;
  volatile BOOL pitchReady;
  VBYEQState eq;
  struct VBYRenderContext *next;
} VBYRenderContext;

static NSString *const kVBYRememberPitchKey = @"VBYRememberPitch";
static NSString *const kVBYPitchKey = @"VBYPitchSemitones";
static NSString *const kVBYRememberEQKey = @"VBYRememberEQ";
static NSString *const kVBYEQKeys[VBY_EQ_BANDS] = {
    @"VBYEQ60", @"VBYEQ250", @"VBYEQ1000", @"VBYEQ4000", @"VBYEQ16000"};

static volatile BOOL gVBYMasterEnabled = YES;
static volatile BOOL gVBYRememberPitch = YES;
static volatile BOOL gVBYRememberEQ = YES;
static volatile float gVBYPitchSemitones = 0.0f;
static volatile float gVBYEQGains[VBY_EQ_BANDS] = {0};
static volatile uint32_t gVBYEQGeneration = 1;
static VBYRenderContext *gVBYContexts = NULL;
static os_unfair_lock gVBYContextsLock = OS_UNFAIR_LOCK_INIT;
static BOOL gVBYEngineInitialized = NO;

static OSStatus (*VBYOriginalAudioUnitSetProperty)(
    AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement,
    const void *, UInt32) = NULL;
static OSStatus (*VBYOriginalAudioUnitInitialize)(AudioUnit) = NULL;

static const float gVBYEQFrequencies[VBY_EQ_BANDS] = {
    60.0f, 250.0f, 1000.0f, 4000.0f, 16000.0f};

static float VBYClamp(float value, float low, float high) {
  if (value < low) return low;
  if (value > high) return high;
  return value;
}

static BOOL VBYHasEQ(void) {
  for (NSUInteger i = 0; i < VBY_EQ_BANDS; i++) {
    if (fabsf(gVBYEQGains[i]) > 0.001f) return YES;
  }
  return NO;
}

static BOOL VBYIsOutputAudioUnit(AudioUnit unit) {
  if (!unit) return NO;
  AudioComponent component = AudioComponentInstanceGetComponent(unit);
  if (!component) return NO;
  AudioComponentDescription desc;
  memset(&desc, 0, sizeof(desc));
  if (AudioComponentGetDescription(component, &desc) != noErr) return NO;
  return desc.componentType == kAudioUnitType_Output;
}

static BOOL VBYTryReadFormat(AudioUnit unit, AudioUnitScope scope,
                             AudioUnitElement element,
                             AudioStreamBasicDescription *format) {
  UInt32 size = sizeof(*format);
  memset(format, 0, sizeof(*format));
  if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element,
                           format, &size) != noErr)
    return NO;
  return format->mFormatID == kAudioFormatLinearPCM &&
         format->mSampleRate > 0.0 &&
         format->mChannelsPerFrame > 0 &&
         format->mChannelsPerFrame <= VBY_MAX_CHANNELS;
}

static BOOL VBYReadPlaybackFormat(AudioUnit unit, AudioUnitElement element,
                                  AudioStreamBasicDescription *format) {
  if (VBYTryReadFormat(unit, kAudioUnitScope_Input, element, format)) return YES;
  if (element != 0 &&
      VBYTryReadFormat(unit, kAudioUnitScope_Input, 0, format))
    return YES;
  if (VBYTryReadFormat(unit, kAudioUnitScope_Output, element, format)) return YES;
  if (element != 0 &&
      VBYTryReadFormat(unit, kAudioUnitScope_Output, 0, format))
    return YES;
  return NO;
}

static void VBYResetBiquad(VBYBiquad *filter) {
  memset(filter->z1, 0, sizeof(filter->z1));
  memset(filter->z2, 0, sizeof(filter->z2));
}

static void VBYConfigureBiquad(VBYBiquad *filter, double sampleRate,
                               float frequency, float gainDB) {
  if (!filter || sampleRate <= 0.0) return;
  float maxFrequency = (float)sampleRate * 0.45f;
  frequency = VBYClamp(frequency, 20.0f, maxFrequency);
  float A = powf(10.0f, gainDB / 40.0f);
  float w0 = 2.0f * (float)M_PI * frequency / (float)sampleRate;
  float cw = cosf(w0);
  float sw = sinf(w0);
  float alpha = sw / (2.0f * 0.9f);
  float b0 = 1.0f + alpha * A;
  float b1 = -2.0f * cw;
  float b2 = 1.0f - alpha * A;
  float a0 = 1.0f + alpha / A;
  float a1 = -2.0f * cw;
  float a2 = 1.0f - alpha / A;
  if (fabsf(a0) < 0.000001f) {
    filter->b0 = 1.0f;
    filter->b1 = 0.0f;
    filter->b2 = 0.0f;
    filter->a1 = 0.0f;
    filter->a2 = 0.0f;
  } else {
    filter->b0 = b0 / a0;
    filter->b1 = b1 / a0;
    filter->b2 = b2 / a0;
    filter->a1 = a1 / a0;
    filter->a2 = a2 / a0;
  }
  VBYResetBiquad(filter);
}

static void VBYConfigureEQ(VBYEQState *state,
                           const AudioStreamBasicDescription *format) {
  if (!state || !format || format->mSampleRate <= 0.0) return;
  state->format = *format;
  state->generation = gVBYEQGeneration;
  for (NSUInteger i = 0; i < VBY_EQ_BANDS; i++) {
    VBYConfigureBiquad(&state->bands[i], format->mSampleRate,
                       gVBYEQFrequencies[i], gVBYEQGains[i]);
  }
}

static inline float VBYRunBiquad(VBYBiquad *filter, UInt32 channel, float x) {
  float y = filter->b0 * x + filter->z1[channel];
  filter->z1[channel] =
      filter->b1 * x - filter->a1 * y + filter->z2[channel];
  filter->z2[channel] = filter->b2 * x - filter->a2 * y;
  return y;
}

static inline float VBYRunEQSample(VBYEQState *state, UInt32 channel, float x) {
  float y = x;
  for (NSUInteger i = 0; i < VBY_EQ_BANDS; i++) {
    if (fabsf(gVBYEQGains[i]) > 0.001f)
      y = VBYRunBiquad(&state->bands[i], channel, y);
  }
  return y;
}

static inline int16_t VBYFloatToS16(float value) {
  value = VBYClamp(value, -1.0f, 0.9999695f);
  return (int16_t)lrintf(value * 32768.0f);
}

static inline int32_t VBYFloatToS32(float value) {
  if (value >= 1.0f) return INT32_MAX;
  if (value <= -1.0f) return INT32_MIN;
  return (int32_t)llrint((double)value * 2147483648.0);
}

static void VBYProcessEQ(VBYEQState *state,
                         const AudioStreamBasicDescription *format,
                         AudioBufferList *buffers, UInt32 frames) {
  if (!state || !format || !buffers || frames == 0 || !VBYHasEQ()) return;
  UInt32 channels = format->mChannelsPerFrame;
  if (channels == 0 || channels > VBY_MAX_CHANNELS) return;
  BOOL isFloat = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
  BOOL isSigned =
      (format->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
  BOOL nonInterleaved =
      (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
  UInt32 bits = format->mBitsPerChannel;
  if (!((isFloat && bits == 32) ||
        (isSigned && (bits == 16 || bits == 32))))
    return;

  if (state->generation != gVBYEQGeneration ||
      fabs(state->format.mSampleRate - format->mSampleRate) > 0.5 ||
      state->format.mChannelsPerFrame != channels ||
      state->format.mFormatFlags != format->mFormatFlags ||
      state->format.mBitsPerChannel != bits) {
    VBYConfigureEQ(state, format);
  }

  for (UInt32 b = 0; b < buffers->mNumberBuffers; b++) {
    AudioBuffer *buffer = &buffers->mBuffers[b];
    if (!buffer->mData || buffer->mDataByteSize == 0) continue;

    if (nonInterleaved) {
      UInt32 channel = b;
      if (channel >= channels) continue;
      if (isFloat) {
        UInt32 count =
            MIN(frames, buffer->mDataByteSize / (UInt32)sizeof(float));
        float *p = (float *)buffer->mData;
        for (UInt32 i = 0; i < count; i++)
          p[i] = VBYRunEQSample(state, channel, p[i]);
      } else if (bits == 16) {
        UInt32 count =
            MIN(frames, buffer->mDataByteSize / (UInt32)sizeof(int16_t));
        int16_t *p = (int16_t *)buffer->mData;
        for (UInt32 i = 0; i < count; i++) {
          float x = (float)p[i] / 32768.0f;
          p[i] = VBYFloatToS16(VBYRunEQSample(state, channel, x));
        }
      } else {
        UInt32 count =
            MIN(frames, buffer->mDataByteSize / (UInt32)sizeof(int32_t));
        int32_t *p = (int32_t *)buffer->mData;
        for (UInt32 i = 0; i < count; i++) {
          float x = (float)((double)p[i] / 2147483648.0);
          p[i] = VBYFloatToS32(VBYRunEQSample(state, channel, x));
        }
      }
      continue;
    }

    if (isFloat) {
      UInt32 count = MIN(
          frames,
          buffer->mDataByteSize / (UInt32)(sizeof(float) * channels));
      float *p = (float *)buffer->mData;
      for (UInt32 f = 0; f < count; f++) {
        for (UInt32 c = 0; c < channels; c++) {
          UInt32 i = f * channels + c;
          p[i] = VBYRunEQSample(state, c, p[i]);
        }
      }
    } else if (bits == 16) {
      UInt32 count = MIN(
          frames,
          buffer->mDataByteSize / (UInt32)(sizeof(int16_t) * channels));
      int16_t *p = (int16_t *)buffer->mData;
      for (UInt32 f = 0; f < count; f++) {
        for (UInt32 c = 0; c < channels; c++) {
          UInt32 i = f * channels + c;
          float x = (float)p[i] / 32768.0f;
          p[i] = VBYFloatToS16(VBYRunEQSample(state, c, x));
        }
      }
    } else {
      UInt32 count = MIN(
          frames,
          buffer->mDataByteSize / (UInt32)(sizeof(int32_t) * channels));
      int32_t *p = (int32_t *)buffer->mData;
      for (UInt32 f = 0; f < count; f++) {
        for (UInt32 c = 0; c < channels; c++) {
          UInt32 i = f * channels + c;
          float x = (float)((double)p[i] / 2147483648.0);
          p[i] = VBYFloatToS32(VBYRunEQSample(state, c, x));
        }
      }
    }
  }
}

static OSStatus VBYPitchInputCallback(
    void *refCon, AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
    UInt32 inNumberFrames, AudioBufferList *ioData) {
  VBYRenderContext *context = (VBYRenderContext *)refCon;
  if (!context || !context->originalProc) return kAudio_ParamError;
  return context->originalProc(context->originalRefCon, ioActionFlags,
                               inTimeStamp, context->element, inNumberFrames,
                               ioData);
}

static void VBYDisposePitchUnit(VBYRenderContext *context) {
  if (!context || !context->pitchUnit) return;
  AudioUnitUninitialize(context->pitchUnit);
  AudioComponentInstanceDispose(context->pitchUnit);
  context->pitchUnit = NULL;
  context->pitchReady = NO;
}

static BOOL VBYConfigurePitchUnit(VBYRenderContext *context) {
  if (!context || !context->hasFormat || !VBYOriginalAudioUnitSetProperty ||
      !VBYOriginalAudioUnitInitialize)
    return NO;

  VBYDisposePitchUnit(context);

  AudioComponentDescription desc;
  memset(&desc, 0, sizeof(desc));
  desc.componentType = kAudioUnitType_FormatConverter;
  desc.componentSubType = kAudioUnitSubType_NewTimePitch;
  desc.componentManufacturer = kAudioUnitManufacturer_Apple;

  AudioComponent component = AudioComponentFindNext(NULL, &desc);
  if (!component) return NO;

  AudioUnit unit = NULL;
  if (AudioComponentInstanceNew(component, &unit) != noErr || !unit) return NO;

  AURenderCallbackStruct input;
  input.inputProc = VBYPitchInputCallback;
  input.inputProcRefCon = context;

  OSStatus status = VBYOriginalAudioUnitSetProperty(
      unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
      &input, sizeof(input));
  if (status != noErr) {
    AudioComponentInstanceDispose(unit);
    return NO;
  }

  AudioStreamBasicDescription format = context->format;
  status = VBYOriginalAudioUnitSetProperty(
      unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format,
      sizeof(format));
  if (status == noErr) {
    status = VBYOriginalAudioUnitSetProperty(
        unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
        &format, sizeof(format));
  }

  UInt32 maxFrames = 0;
  UInt32 maxFramesSize = sizeof(maxFrames);
  if (AudioUnitGetProperty(context->outputUnit,
                           kAudioUnitProperty_MaximumFramesPerSlice,
                           kAudioUnitScope_Global, 0, &maxFrames,
                           &maxFramesSize) == noErr &&
      maxFrames > 0) {
    VBYOriginalAudioUnitSetProperty(
        unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global,
        0, &maxFrames, sizeof(maxFrames));
  }

  if (status == noErr)
    status = AudioUnitSetParameter(unit, kNewTimePitchParam_Rate,
                                   kAudioUnitScope_Global, 0, 1.0f, 0);
  if (status == noErr)
    status = AudioUnitSetParameter(
        unit, kNewTimePitchParam_Pitch, kAudioUnitScope_Global, 0,
        VBYClamp(gVBYPitchSemitones, -12.0f, 12.0f) * 100.0f, 0);
  if (status == noErr) status = VBYOriginalAudioUnitInitialize(unit);

  if (status != noErr) {
    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);
    return NO;
  }

  context->pitchUnit = unit;
  context->pitchReady = YES;
  return YES;
}

static OSStatus VBYEffectsRenderCallback(
    void *refCon, AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
    UInt32 inNumberFrames, AudioBufferList *ioData) {
  VBYRenderContext *context = (VBYRenderContext *)refCon;
  if (!context || !context->originalProc) return kAudio_ParamError;

  OSStatus status = noErr;
  BOOL usePitch = gVBYMasterEnabled && ioData &&
                  fabsf(gVBYPitchSemitones) > 0.001f &&
                  context->pitchReady && context->pitchUnit;

  if (usePitch) {
    status = AudioUnitRender(context->pitchUnit, ioActionFlags, inTimeStamp, 0,
                             inNumberFrames, ioData);
    if (status != noErr) {
      context->pitchReady = NO;
      status = context->originalProc(
          context->originalRefCon, ioActionFlags, inTimeStamp, inBusNumber,
          inNumberFrames, ioData);
    }
  } else {
    status = context->originalProc(
        context->originalRefCon, ioActionFlags, inTimeStamp, inBusNumber,
        inNumberFrames, ioData);
  }

  if (status == noErr && gVBYMasterEnabled && context->hasFormat && ioData)
    VBYProcessEQ(&context->eq, &context->format, ioData, inNumberFrames);

  return status;
}

static void VBYRegisterContext(VBYRenderContext *context) {
  os_unfair_lock_lock(&gVBYContextsLock);
  context->next = gVBYContexts;
  gVBYContexts = context;
  os_unfair_lock_unlock(&gVBYContextsLock);
}

static void VBYRefreshContexts(AudioUnit unit) {
  os_unfair_lock_lock(&gVBYContextsLock);
  for (VBYRenderContext *context = gVBYContexts; context;
       context = context->next) {
    if (context->outputUnit != unit) continue;
    AudioStreamBasicDescription format;
    if (VBYReadPlaybackFormat(context->outputUnit, context->element, &format)) {
      context->format = format;
      context->hasFormat = YES;
      context->eq.generation = 0;
      VBYConfigurePitchUnit(context);
    }
  }
  os_unfair_lock_unlock(&gVBYContextsLock);
}

static OSStatus VBYHookedAudioUnitSetProperty(
    AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope,
    AudioUnitElement inElement, const void *inData, UInt32 inDataSize) {
  if (!VBYOriginalAudioUnitSetProperty) return kAudio_ParamError;

  if (inID == kAudioUnitProperty_SetRenderCallback &&
      inScope == kAudioUnitScope_Input && inData &&
      inDataSize >= sizeof(AURenderCallbackStruct) &&
      VBYIsOutputAudioUnit(inUnit)) {
    const AURenderCallbackStruct *incoming =
        (const AURenderCallbackStruct *)inData;
    if (incoming->inputProc &&
        incoming->inputProc != VBYEffectsRenderCallback) {
      VBYRenderContext *context =
          (VBYRenderContext *)calloc(1, sizeof(VBYRenderContext));
      if (context) {
        context->outputUnit = inUnit;
        context->element = inElement;
        context->originalProc = incoming->inputProc;
        context->originalRefCon = incoming->inputProcRefCon;
        context->hasFormat =
            VBYReadPlaybackFormat(inUnit, inElement, &context->format);
        if (context->hasFormat) VBYConfigurePitchUnit(context);

        AURenderCallbackStruct wrapped;
        wrapped.inputProc = VBYEffectsRenderCallback;
        wrapped.inputProcRefCon = context;

        OSStatus status = VBYOriginalAudioUnitSetProperty(
            inUnit, inID, inScope, inElement, &wrapped, sizeof(wrapped));
        if (status == noErr) {
          VBYRegisterContext(context);
          return status;
        }

        VBYDisposePitchUnit(context);
        free(context);
      }
    }
  }

  OSStatus status = VBYOriginalAudioUnitSetProperty(
      inUnit, inID, inScope, inElement, inData, inDataSize);
  if (status == noErr && inID == kAudioUnitProperty_StreamFormat)
    VBYRefreshContexts(inUnit);
  return status;
}

static OSStatus VBYHookedAudioUnitInitialize(AudioUnit inUnit) {
  if (!VBYOriginalAudioUnitInitialize) return kAudio_ParamError;
  OSStatus status = VBYOriginalAudioUnitInitialize(inUnit);
  if (status == noErr) VBYRefreshContexts(inUnit);
  return status;
}

static void VBYLoadAudioPreferences(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

  gVBYRememberPitch =
      [defaults objectForKey:kVBYRememberPitchKey] == nil
          ? YES
          : [defaults boolForKey:kVBYRememberPitchKey];
  if (gVBYRememberPitch && [defaults objectForKey:kVBYPitchKey] != nil)
    gVBYPitchSemitones =
        VBYClamp([defaults floatForKey:kVBYPitchKey], -12.0f, 12.0f);
  else
    gVBYPitchSemitones = 0.0f;

  gVBYRememberEQ =
      [defaults objectForKey:kVBYRememberEQKey] == nil
          ? YES
          : [defaults boolForKey:kVBYRememberEQKey];

  for (NSUInteger i = 0; i < VBY_EQ_BANDS; i++) {
    if (gVBYRememberEQ && [defaults objectForKey:kVBYEQKeys[i]] != nil)
      gVBYEQGains[i] =
          VBYClamp([defaults floatForKey:kVBYEQKeys[i]], -12.0f, 12.0f);
    else
      gVBYEQGains[i] = 0.0f;
  }
}

void VBYAudioEngineInitialize(void) {
  if (gVBYEngineInitialized) return;
  gVBYEngineInitialized = YES;
  VBYLoadAudioPreferences();

  struct rebinding bindings[2];
  bindings[0].name = "AudioUnitSetProperty";
  bindings[0].replacement = (void *)VBYHookedAudioUnitSetProperty;
  bindings[0].replaced = (void **)&VBYOriginalAudioUnitSetProperty;
  bindings[1].name = "AudioUnitInitialize";
  bindings[1].replacement = (void *)VBYHookedAudioUnitInitialize;
  bindings[1].replaced = (void **)&VBYOriginalAudioUnitInitialize;
  rebind_symbols(bindings, 2);
}

void VBYAudioEngineSetMasterEnabled(BOOL enabled) {
  gVBYMasterEnabled = enabled;
}

float VBYGetPitchSemitones(void) {
  return VBYClamp(gVBYPitchSemitones, -12.0f, 12.0f);
}

void VBYSetPitchSemitones(float value) {
  value = VBYClamp(value, -12.0f, 12.0f);
  gVBYPitchSemitones = value;

  if (gVBYRememberPitch) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setFloat:value forKey:kVBYPitchKey];
    [defaults synchronize];
  }

  os_unfair_lock_lock(&gVBYContextsLock);
  for (VBYRenderContext *context = gVBYContexts; context;
       context = context->next) {
    if (context->pitchReady && context->pitchUnit)
      AudioUnitSetParameter(context->pitchUnit, kNewTimePitchParam_Pitch,
                            kAudioUnitScope_Global, 0, value * 100.0f, 0);
  }
  os_unfair_lock_unlock(&gVBYContextsLock);
}

BOOL VBYIsRememberPitchEnabled(void) {
  return gVBYRememberPitch;
}

void VBYSetRememberPitchEnabled(BOOL enabled) {
  gVBYRememberPitch = enabled;
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setBool:enabled forKey:kVBYRememberPitchKey];
  if (enabled)
    [defaults setFloat:VBYGetPitchSemitones() forKey:kVBYPitchKey];
  else
    [defaults removeObjectForKey:kVBYPitchKey];
  [defaults synchronize];
}

float VBYGetEQGain(NSUInteger index) {
  if (index >= VBY_EQ_BANDS) return 0.0f;
  return VBYClamp(gVBYEQGains[index], -12.0f, 12.0f);
}

void VBYSetEQGain(NSUInteger index, float value) {
  if (index >= VBY_EQ_BANDS) return;
  value = VBYClamp(value, -12.0f, 12.0f);
  gVBYEQGains[index] = value;
  uint32_t next = gVBYEQGeneration + 1;
  gVBYEQGeneration = next == 0 ? 1 : next;

  if (gVBYRememberEQ) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setFloat:value forKey:kVBYEQKeys[index]];
    [defaults synchronize];
  }
}

void VBYResetEQ(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  for (NSUInteger i = 0; i < VBY_EQ_BANDS; i++) {
    gVBYEQGains[i] = 0.0f;
    if (gVBYRememberEQ) [defaults setFloat:0.0f forKey:kVBYEQKeys[i]];
  }
  uint32_t next = gVBYEQGeneration + 1;
  gVBYEQGeneration = next == 0 ? 1 : next;
  if (gVBYRememberEQ) [defaults synchronize];
}

BOOL VBYIsRememberEQEnabled(void) {
  return gVBYRememberEQ;
}

void VBYSetRememberEQEnabled(BOOL enabled) {
  gVBYRememberEQ = enabled;
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setBool:enabled forKey:kVBYRememberEQKey];
  for (NSUInteger i = 0; i < VBY_EQ_BANDS; i++) {
    if (enabled)
      [defaults setFloat:VBYGetEQGain(i) forKey:kVBYEQKeys[i]];
    else
      [defaults removeObjectForKey:kVBYEQKeys[i]];
  }
  [defaults synchronize];
}
