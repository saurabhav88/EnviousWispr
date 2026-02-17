import Testing

@Test func appConstantsExist() {
    #expect(AppConstants.appName == "VibeWhisper")
    #expect(AppConstants.sampleRate == 16000.0)
    #expect(AppConstants.audioChannels == 1)
}
