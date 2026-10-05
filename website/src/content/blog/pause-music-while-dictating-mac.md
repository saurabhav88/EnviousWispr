---
title: "How to Pause Music Automatically While You Dictate on a Mac"
description: "Stop background music from drowning out your dictation. Pause, lower or mute it only while you speak, and have it come back when you stop."
topic: tips-troubleshooting
pubDate: 2026-09-28
tags: ["dictation", "macos", "audio", "productivity"]
draft: false
author: "Saurabh Vaish"
keywords:
  - "pause music while dictating mac"
  - "mute audio when dictating"
  - "dictation background music"
  - "lower volume while dictating mac"
  - "spotify pauses when dictating"
faqs:
  - question: "Can my Mac pause music automatically while I dictate?"
    answer: "Yes, with EnviousWispr, a free dictation app for Mac. Open Settings, Microphone, and under Media during dictation choose Pause. What was playing, such as Spotify, Music, a YouTube tab or a podcast app, pauses when you start dictating and resumes when you stop. If a macOS update turns off the part of macOS it uses for this, Pause falls back to Music and Spotify only, and the Microphone page says so."
  - question: "What is the difference between Lower, Mute and Pause?"
    answer: "Lower turns your current speakers or headphones down to about half for the whole take and puts the volume back after, unless you changed the volume yourself during the take. Mute silences that output for the take. Pause stops what was playing and resumes it when you finish. Continue, the starting choice, leaves your audio alone."
  - question: "Will Lower or Mute also quiet a video call?"
    answer: "Yes. Lower and Mute act on everything your Mac plays through that output, including a call in progress and spoken feedback from a screen reader. Pause only affects what was playing when you started."
  - question: "Why does background music affect dictation at all?"
    answer: "If your speakers are playing music, your microphone can pick it up alongside your voice. Pausing or muting the music while you talk keeps that sound out of the recording, and lowering it makes it quieter."
---

You are listening to a playlist, you press your dictation key, and you start talking over the chorus. The microphone hears both of you. Or you are wearing headphones and realise halfway through a sentence that you cannot hear yourself think over the podcast.

The usual fix is to reach for the pause key before every dictation and remember to press it again after. This post shows how to have that happen on its own, using EnviousWispr, a free dictation app for Mac.

## The setting: Media during dictation

Click the EnviousWispr icon in your menu bar, choose **Open EnviousWispr**, and go to **Dictation Settings** > **Microphone**. Above Microphone readiness is **Media during dictation**, with four choices:

| Choice | What it does while you dictate | When you stop |
|---|---|---|
| **Continue** | Leaves your audio playing as it is | Nothing to undo |
| **Lower** | Turns your current speakers or headphones down to about half | Puts the volume back where it was, unless you changed it during the take |
| **Mute** | Silences your current speakers or headphones | Puts the volume back, unless you changed it during the take |
| **Pause** | Pauses what is playing: Spotify, Music, a YouTube tab, a podcast app | Resumes the same song or video, if it is still the paused item |

It starts on **Continue**, so nothing changes until you choose another option.

## Which one to pick

**Pause** suits music and podcasts, where you would rather not miss anything. The same song or episode picks up where it stopped. Only what was playing when you started is paused; anything you start during the dictation keeps going.

**Lower** suits background music you do not mind hearing faintly.

**Mute** is the simplest when you want silence and do not care where the music was.

## Things worth knowing

- **Lower and Mute act on the whole output.** They quiet everything your Mac plays through those speakers or headphones, including a call in progress and spoken feedback from a screen reader.
- **The output is the one in use when you start.** If you switch from speakers to headphones halfway through a dictation, the new output is not lowered or muted.
- **Your own volume change wins.** If you change the volume yourself during a take, your new level stays. EnviousWispr only puts the volume back when it is still at the level it set.
- **Pause can fall back to Music and Spotify.** Pause reaches every player through a part of macOS that Apple has not opened up to apps. If a macOS update turns that off, EnviousWispr falls back to pausing Music and Spotify only, and the Microphone page says so. On that fallback, macOS asks the first time whether EnviousWispr may control Music or Spotify; that first take is not paused, and every take after you allow it is.
- **Some outputs cannot be turned down.** A display over HDMI, for example, does not let apps change its volume. The Microphone page tells you when Lower or Mute is not available on your current output.
- **It helps keep music out of your recording.** Music from your speakers can end up in the recording alongside your voice. Pause and Mute keep it out; Lower makes it quieter.

## Other things that help a clean recording

Background music is one source of noise. If your dictation is still picking up the room, the help article [Choosing Your Microphone](/help/choosing-your-microphone/) covers which input to use, and [Noise Suppression](/help/noise-suppression/) explains why EnviousWispr records your microphone as it is and leaves the audio to the speech model. If you work somewhere you cannot raise your voice, [Dictate in a Whisper](/blog/dictate-in-a-whisper-soft-speech/) covers quiet speech.

## The takeaway

You do not need to reach for the pause key before every dictation. Set **Media during dictation** to Pause, Lower or Mute once, and your music gets out of the way when you speak and comes back when you stop. The rest of the ways to shape how EnviousWispr sounds and behaves are on the [Make it yours](/customization/) page.
