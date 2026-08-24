# Altium_Schematic_Groupper

Groups PCB footprints by the schematic sheet they came from, right after
Update PCB, so you can tackle a design one sheet at a time instead of hunting
parts scattered across the board.

## What it does

For every `.SchDoc` in the focused project, it moves that sheet's placed
components' footprints into one tidy, labelled cluster in the staging area to
the right of the board outline - one cluster per sheet, stacked top to
bottom. Each footprint is matched to its schematic component by designator.

This is the scripted equivalent of the manual routine most people already do:
cross select a sheet's parts in Schematic, then in PCB run
**Tools > Component Placement > Reposition Selected Components**. That
command is click-driven (each selected part follows the cursor until you
click to drop it), so it can't be run from a script without a mouse - this
shelf-packs every footprint on a sheet, left to right and wrapping like text,
and moves each one there directly instead. Each part gets a cell sized to
its own footprint, not a uniform grid cell, so fifty 0402s next to one big
connector pack in tight instead of each sitting in a cell sized for the
connector.

## Run

1. Open your project (schematic sheets + the one PCB document already
   Updated from them).
2. `File > Open...` and pick `Altium_Schematic_Groupper.pas` (or open
   `Altium_Schematic_Groupper.PrjScr` as a project), then **Run Script** and
   choose `RunSchematicGroupper`.
3. Confirm the prompt. It moves every matched footprint, so it's worth
   knowing up front: **everything already placed gets pulled into the
   staging area too**, since matching is by designator, not by current
   position. Run it right after Update PCB, before you've placed anything by
   hand - or just Ctrl+Z afterward if it fires at the wrong moment.

## After it runs

- Each sheet's parts sit in a boxed cluster to the right of the board,
  labelled with the sheet's file name, e.g. `PowerSupply.SchDoc`.
- The boxes/labels live on **Mechanical layer 16**, named `Grouping`, shown by
  default and set to **yellow** - a work aid, not board data. Delete that
  layer's objects (or just hide the layer) once you've placed everything.
- That yellow is an Altium **preference**, not something stored in this
  board - see "Layer colour is a global preference" below before you run
  this on a project where Mechanical 16 already means something else.
- Drag each cluster onto the board as a block, the same way you would after
  the manual cross-select + reposition routine.
- One Ctrl+Z undoes the whole run (each moved footprint is its own undo
  step, so it may take more than one press to get all the way back).

## Requirements / limits

- The PCB must already be in sync with the schematic (**Design > Update PCB
  Document**). A schematic component with no matching footprint on the board
  is skipped and listed by name in the closing summary - useful as a sync
  check in its own right.
- Expects a single-board project (exactly one `.PcbDoc`). Multi-board
  projects aren't handled.
- Packing is a simple left-to-right shelf pack (wraps to a new row past 150 mm
  of width), not a true bin-packer - it's meant to be a tight staging cluster
  you grab and place as a block, not a finished layout, so don't expect
  optimal density.
- Built by matching the proven idioms in `Altium_Ez_Panelizer.pas` (same repo
  pattern one folder up) and by confirming every new API call
  (`SchIterator_*`, `DM_LogicalDocuments`, `GetPcbComponentByRefDes`, ...)
  actually exists in this install's `ScriptingSystem.dll` before using it. If
  `RunSchematicGroupper` doesn't show up in the Run Script list at all,
  something here doesn't compile on your Altium build - let me know what else
  was in the list and I'll adjust.

## Known issue, fixed 2026-08-24

First run left the PCB document refusing to close or accept any further
edits, even though the script completed and showed its summary. Root cause:
`MoveToXY` was wrapped in a `BeginModify`/`EndModify` message pair with no
exception guard around it. If `MoveToXY` threw for even one footprint
(locked, room-constrained, whatever), `EndModify` for that object never
fired - and one dangling `BeginModify` is enough to leave the whole document
stuck in an editing state Altium won't let you close or modify out of.

Fixed by putting `EndModify` in a `Finally` so it always fires, and by no
longer holding `PCBServer.PreProcess`/`PostProcess` open across the schematic
document switches (each sheet's PCB-side move now opens and closes its own
narrow transaction). If it happens again: close Altium Designer entirely
(not just the document) without saving - it's an in-memory transaction lock,
not a disk lock, so a full restart clears it and the file on disk is
untouched.

## Layer colour is a global preference, not board data

`MLayer.Color` and `Board.LayerColors_V7[LabelLayer]` were both tried first
and both are "undeclared identifier" on this build - both names turned up in
the `ScriptingSystem.dll` string scan, which only proves the name exists
somewhere in the binary, not that it belongs to the class being called on
(see the "verification rule" in `Altium_Ez_Panelizer.pas`'s `NOTES.md` one
folder up).

The mechanism that actually works is `RunProcess('Pcb:SetupPreferences')`
with a `MechanicalNColor` string parameter, taken directly from Altium's own
shipped example script (`Delphiscript Scripts/Processes/pcbcolor.pas` in
their `scripting-reference` GitHub repo) rather than guessed. Two things
about it that matter:

- **It only covers Mechanical layers 1-16.** That's why the group-box layer
  moved from 31 to **16** - layer 31 has no `MechanicalNColor` parameter at
  all, full stop. If Mechanical 16 already means something specific in your
  templates, change `cLabelLayerNo` in the script to a free layer in 1-16
  before running it, or the color-setting step will just silently recolour
  whatever that layer already holds (wrapped in its own `Try/Except`, so it
  fails soft either way - the boxes/labels themselves are unaffected).
- **It's an application preference, not a document property.** Setting
  `Mechanical16Color` changes what that layer number displays as in every
  board you open in this copy of Altium from now on - it is the same setting
  as the PCB Editor - Layer Colors page in Preferences, just reached through
  script instead of the dialog. It is not stored in the `.PcbDoc` file and
  will not travel with the project to another machine.
