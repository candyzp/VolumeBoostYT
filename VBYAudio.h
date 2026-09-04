#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

float VBYGetVolumeMultiplier(void);
void VBYSetVolumeMultiplier(float multiplier);
BOOL VBYIsVolumeBoostYTEnabled(void);
BOOL VBYIsRememberVolumeEnabled(void);
BOOL VBYIsLegacyUIEnabled(void);
void VBYSetLegacyUIEnabled(BOOL enabled);
BOOL VBYIsPlayerButtonEnabled(void);
void VBYSetPlayerButtonEnabled(BOOL enabled);
BOOL VBYIsShortsButtonEnabled(void);
void VBYSetShortsButtonEnabled(BOOL enabled);

void VBYAudioEngineInitialize(void);
float VBYGetPitchSemitones(void);
void VBYSetPitchSemitones(float value);
BOOL VBYIsRememberPitchEnabled(void);
void VBYSetRememberPitchEnabled(BOOL enabled);
float VBYGetEQGain(NSUInteger index);
void VBYSetEQGain(NSUInteger index, float value);
void VBYResetEQ(void);
BOOL VBYIsRememberEQEnabled(void);
void VBYSetRememberEQEnabled(BOOL enabled);
void VBYAudioEngineSetMasterEnabled(BOOL enabled);

void VBYAudioPanelPresent(void);
void VBYAudioPanelSetPlaying(BOOL playing);
void VBYAudioPanelPlayerStateChanged(AVPlayer *player);
void VBYAudioPanelRefresh(void);
