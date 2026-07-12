# Progress Presentation Implementation Plan

1. Add persisted Used/Left, Left direction, and 10%-step overlay opacity preferences, presented as inverse transparency in Settings.
2. Centralize used-to-display conversion in a pure presentation helper.
3. Route all quota headers, compact percentages, and shared tracks through that helper.
4. Make Icon and Overlap time presentation follow the selected mode and anchor.
5. Add a 1px same-color time border with opacity 15 percentage points below the fill.
6. Verify configuration behavior, all display combinations, build, tests, assembly, and native screenshots.
