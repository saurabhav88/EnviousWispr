# Old German name stays on the card only (#4320)

The council round 2 blocks kept "Live-Transkript" (the old German name) as a search word on
meetingLiveWords and on its four controls (.apple, .change, .keepCurrent, .universal).

SettingsSearchBothLegsTests ("Live Preview finds both dictation's and EnviousMeet's...") expects a
search for "Live-Transkript" to show the card first. With the word on all five entries it showed
meetingLiveWords.change first (build/logs/chunk7-rerun.log).

Change: "Live-Transkript" is removed from the German words of the four controls. The card keeps it.
No word or phrase was added; every other block is unchanged. The four controls are still found by
their German phrases, which name "Live-Vorschau".
