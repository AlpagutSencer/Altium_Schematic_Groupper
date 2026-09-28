# Altium_Schematic_Groupper

An Altium Designer script that groups PCB footprints by the schematic sheet they
came from, right after Update PCB, so you can place a design one sheet at a time
instead of hunting for parts scattered across the board.

Developed against Altium Designer. DelphiScript, no SDK required.

## What it does

For every `.SchDoc` in the focused project, it moves the footprints of that
sheet's components into one labelled cluster in the staging area to the right of
the board outline: one cluster per sheet, stacked top to bottom. Footprints are
matched to schematic components by designator.

This is the scripted version of the manual routine most people already use:
cross-select a sheet's parts in the schematic, then in the PCB run
**Tools > Component Placement > Reposition Selected Components**. That command
is click-driven (each part follows the cursor until you click to drop it), so it
can't be scripted. Instead, this script shelf-packs each sheet's footprints left
to right, wrapping like text, and moves each one there directly. Each part gets
a cell sized to its own footprint, not a uniform grid cell, so fifty 0402s next
to one big connector pack tightly instead of each sitting in a connector-sized
cell.

## Run

1. Open your project: the schematic sheets and the one PCB document, already
   updated from them (**Design > Update PCB Document**).
2. **Save the PCB.** See [Undo](#undo) for why.
3. `File > Open...` and pick `Altium_Schematic_Groupper.pas` (or open
   `Altium_Schematic_Groupper.PrjScr` as a project), then **Run Script** and
   choose `RunSchematicGroupper`.
4. Confirm the prompt. The script moves **every** footprint that matches a
   schematic component, including ones you have already placed on the board,
   because matching is by designator, not by position. Run it right after
   Update PCB, before you place anything by hand.

## After it runs

- Each sheet's parts sit in a boxed cluster to the right of the board, labelled
  with the sheet's file name, for example `PowerSupply.SchDoc`.
- Nothing is left selected. To move a cluster, drag a selection window around
  its box, then drag it onto the board.
- The boxes and labels are on **Mechanical layer 16**, which the script enables,
  names `Grouping` and shows. They are a work aid, not board data: delete that
  layer's objects, or hide the layer, once everything is placed.
- The script sets Mechanical 16 to **yellow**. That colour is an Altium
  preference, not part of the board; see
  [Layer colour](#layer-colour-is-a-global-preference-not-board-data).
- The closing summary lists, per sheet, how many footprints were moved out of
  how many components, and names every part it could not handle and why.

## Undo

Every footprint move, and every line and label of the group boxes, is its own
undo step, so reverting a whole run with Ctrl+Z takes many presses. The
quickest full revert is to close the PCB without saving, which is why you save
before running.

Ctrl+Z does not undo:

- Mechanical layer 16 being enabled, named `Grouping` and shown;
- the yellow colour for Mechanical 16, which is an application preference.

## Requirements and limits

- **The PCB must be in sync with the schematic.** A schematic component with no
  matching footprint is skipped and listed in the summary, which also makes the
  script a handy sync check.
- **Single-board projects only**: the project must contain exactly one
  `.PcbDoc`.
- **Multi-channel designs are not supported.** Repeated sheets give the PCB
  channel designators such as `R1_CH1`, which don't match the schematic's `R1`,
  so those parts are reported as having no footprint.
- **A component with parts on several sheets** (for example `U1A` on one sheet
  and `U1B` on another) is grouped with the first sheet that uses it, and listed
  in the summary for the later ones.
- **Packing is a simple shelf pack** that wraps to a new row past 150 mm of
  width. It makes a tight staging cluster to grab and place as a block, not a
  finished layout.
- **Arc-shaped board edges:** the staging area starts 10 mm to the right of the
  board's bounding box. The script reads the outline's full bounding rectangle,
  and falls back to the outline's corner points only if that fails.

## How it was built

The script reuses DelphiScript idioms already proven in
[Altium_EZ_Panelizer](https://github.com/AlpagutSencer/Altium_EZ_Panelizer), and
every newer API call (`SchIterator_*`, `DM_LogicalDocuments`,
`GetPcbComponentByRefDes`, ...) was checked to exist in Altium's
`ScriptingSystem.dll` before use. If `RunSchematicGroupper` doesn't appear in the
Run Script list at all, something in the script doesn't compile on your Altium
build; please open an issue with your Altium version.

## Layer colour is a global preference, not board data

Altium has no per-document layer colour that a script can set:
`MLayer.Color` and `Board.LayerColors_V7[...]` are both "undeclared identifier"
in DelphiScript. The mechanism that works is
`RunProcess('Pcb:SetupPreferences')` with a `MechanicalNColor` parameter, taken
from Altium's own example script (`Delphiscript Scripts/Processes/pcbcolor.pas`
in their `scripting-reference` repository). Two consequences:

- **It only covers Mechanical layers 1-16**, which is why the script uses
  layer 16. If Mechanical 16 already means something in your templates, change
  `cLabelLayerNo` in the script to a free layer between 1 and 16 before running
  it. Otherwise that layer turns yellow in your view (the boxes and labels
  themselves are unaffected either way).
- **It is an application preference.** It changes how that layer number is
  displayed in every board you open in this copy of Altium, exactly like the
  PCB Editor - Layer Colors page in Preferences. It is not stored in the
  `.PcbDoc` and does not travel with the project.

## Changelog

### 1.1 (2026-09-28)

- The summary counts footprints actually moved, not merely found, and names each
  footprint that could not be moved.
- A component with parts on several sheets stays in the first sheet's group
  instead of being moved again by each later sheet.
- Nothing is left selected after the run, so each cluster can be picked up on
  its own.
- The board's bounding box now comes from the outline's full bounding
  rectangle, so arc edges are included.
- Corrected the undo description: undo is one step per move, not one step for
  the whole run, and the layer setup and colour are not undone.
- Documented the multi-channel and multi-sheet-component limits.

### 1.0 (2026-08-24)

- First release.
- Fix: the first test run left the PCB document refusing to close or accept
  edits. `MoveToXY` sat inside a `BeginModify`/`EndModify` pair with no
  exception guard, so a footprint that failed to move left `EndModify` unsent.
  `EndModify` is now in a `Finally`, and each sheet's moves use their own
  `PreProcess`/`PostProcess` transaction instead of one held open across the
  schematic document switches. If it ever happens again, close Altium entirely
  without saving: it is an in-memory lock, and the file on disk is untouched.
