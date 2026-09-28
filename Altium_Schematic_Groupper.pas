{..............................................................................}
{  Altium_Schematic_Groupper.pas                                        v1.1  }
{                                                                              }
{  Groups PCB footprints by the schematic sheet they came from, so a freshly  }
{  imported design can be tackled one sheet at a time instead of hunting      }
{  parts scattered across the board.                                         }
{                                                                              }
{  For every .SchDoc in the focused project, each placed component's PCB     }
{  footprint is pulled into its own tidy cluster in the staging area to the  }
{  right of the board outline, boxed and labelled with the sheet name.       }
{                                                                              }
{  This is the scripted equivalent of the manual routine - cross select a    }
{  sheet's parts in Schematic, then in PCB run Tools > Component Placement > }
{  Reposition Selected Components - except that command is click-driven      }
{  (each selected part follows the cursor until you click to drop it) and    }
{  cannot be run headlessly from a script, so this shelf-packs each sheet's  }
{  footprints - sized to their own bounding boxes, not a uniform grid cell - }
{  and moves each one there directly instead.                                }
{                                                                              }
{  RUN:  open this file (File > Open...) and use Run Script, or open         }
{        Altium_Schematic_Groupper.PrjScr as a project.                      }
{        Entry point: RunSchematicGroupper                                   }
{                                                                              }
{  REQUIRES the PCB to already be in sync with the schematic (Design >       }
{  Update PCB Document). Footprints are matched to schematic parts purely by }
{  designator string; any schematic component with no matching footprint on  }
{  the board is skipped and listed in the closing summary rather than        }
{  guessed at.                                                                }
{                                                                              }
{  The group boxes and labels are drawn on a spare mechanical layer          }
{  (see cLabelLayerNo below) so they never touch a fab layer. Delete or hide  }
{  that layer once you are done placing - it is a work aid, not board data.  }
{                                                                              }
{  UNDO: every footprint move and every box line/label is its own undo step, }
{  so a full revert by Ctrl+Z takes many presses. Save before running; the   }
{  quickest full revert is closing the PCB without saving. Ctrl+Z does not   }
{  touch the Mechanical 16 layer setup or its colour (a global preference).  }
{                                                                              }
{  NOTE: built by matching DelphiScript idioms already proven in             }
{  Altium_EZ_Panelizer (github.com/AlpagutSencer/Altium_EZ_Panelizer) and    }
{  confirming the newer API calls (SchIterator_*, DM_LogicalDocuments,       }
{  GetPcbComponentByRefDes) exist in ScriptingSystem.dll. If Run Script ever }
{  drops this file from its list outright, a property or type in here does   }
{  not compile on your Altium build.                                         }
{..............................................................................}

Const
    cStagingGapMM   = 10.0;   // board edge -> first group, mm
    cGroupGapMM     = 5.0;    // between one sheet's group and the next, mm
    cCellGapMM      = 2.0;    // between footprints inside a group, mm
    cMaxRowSpanMM   = 150.0;  // wrap a group onto a new row past this width, mm
    cDefaultCellMM  = 10.0;   // fallback footprint size if BoundingRectangle fails, mm
    cMaxComps       = 4000;   // footprints tracked per sheet
    // Mechanical layer for the group boxes/labels. Must be 1-16: that is the
    // range Pcb:SetupPreferences exposes a MechanicalNColor parameter for (see
    // the colour-setting block below) - layer 31 could not be recoloured this
    // way at all. 16 was picked as the least likely to already be in template
    // use, not because it is guaranteed free - check your own layer stack.
    cLabelLayerNo   = 16;
    cLabelColor     = '65535'; // TColor, decimal, BGR-encoded - this is yellow
                                // (0x00FFFF: B=00 G=FF R=FF); confirmed against
                                // Altium's own pcbcolor.pas example, which uses
                                // the same value for TopOverlayColor in its
                                // "Classic" scheme (Top Overlay is yellow by
                                // Altium convention).


Function MM(V : Double) : TCoord;
Begin
    Result := MMsToCoord(V);
End;


Function MMStr(C : TCoord) : String;
Begin
    Result := FormatFloat('0.###', CoordToMMs(C));
End;


{  Register a freshly created primitive with the board's undo / DRC system.  }
Procedure RegObj(Board : IPCB_Board; Obj : IPCB_Primitive);
Begin
    Board.AddPCBObject(Obj);
    PCBServer.SendMessageToRobots(Board.I_ObjectAddress, c_Broadcast,
                                  PCBM_BoardRegisteration, Obj.I_ObjectAddress);
End;


Procedure AddLine(Board : IPCB_Board; LayerID : TLayer;
                  X1, Y1, X2, Y2, W : TCoord);
Var
    Trk : IPCB_Track;
Begin
    Trk := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    Trk.X1    := X1;  Trk.Y1 := Y1;
    Trk.X2    := X2;  Trk.Y2 := Y2;
    Trk.Width := W;
    Trk.Layer := LayerID;
    RegObj(Board, Trk);
End;


Procedure AddText(Board : IPCB_Board; LayerID : TLayer;
                  X, Y : TCoord; S : String; H, W : TCoord);
Var
    Txt : IPCB_Text;
Begin
    Txt := PCBServer.PCBObjectFactory(eTextObject, eNoDimension, eCreate_Default);
    Txt.XLocation  := X;
    Txt.YLocation  := Y;
    Txt.Layer      := LayerID;
    Txt.Text       := S;
    Txt.Size       := H;
    Txt.Width      := W;
    Txt.UseTTFonts := False;
    RegObj(Board, Txt);
End;


{  Bounding box of the board outline. The outline's own BoundingRectangle   }
{  includes arc bulges, so it is tried first. The fallback scans the         }
{  segment end points only, which can miss how far an arc edge bulges out -  }
{  acceptable for a staging-area reference, since cStagingGapMM leaves room. }
{..............................................................................}
Function BoardBBox(Board : IPCB_Board; Var X1, Y1, X2, Y2 : TCoord) : Boolean;
Var
    i, n   : Integer;
    vx, vy : TCoord;
    R      : TCoordRect;
Begin
    Result := False;
    // No Exit inside Try here: kept to the plain constructs this script
    // already relies on, since one the interpreter rejects drops the whole
    // script from Run Script.
    Try
        R := Board.BoardOutline.BoundingRectangle;
        If (R.x2 > R.x1) And (R.y2 > R.y1) Then
        Begin
            X1 := R.x1;  Y1 := R.y1;
            X2 := R.x2;  Y2 := R.y2;
            Result := True;
        End;
    Except
        Result := False;
    End;
    If Result Then Exit;

    n := Board.BoardOutline.PointCount;
    If n < 3 Then Exit;

    X1 :=  2000000000;  Y1 :=  2000000000;
    X2 := -2000000000;  Y2 := -2000000000;

    For i := 0 To n - 1 Do
    Begin
        vx := Board.BoardOutline.Segments[i].vx;
        vy := Board.BoardOutline.Segments[i].vy;
        If vx < X1 Then X1 := vx;
        If vy < Y1 Then Y1 := vy;
        If vx > X2 Then X2 := vx;
        If vy > Y2 Then Y2 := vy;
    End;

    Result := (X2 > X1) And (Y2 > Y1);
End;


Function ComponentSize(Comp : IPCB_Component; Var W, H : TCoord) : Boolean;
Var
    R : TCoordRect;
Begin
    Result := False;
    Try
        R := Comp.BoundingRectangle;
        W := R.x2 - R.x1;
        H := R.y2 - R.y1;
        Result := (W > 0) And (H > 0);
    Except
        Result := False;
    End;
End;


{..............................................................................}
{  Move every footprint whose designator is in Designators into one shelf-    }
{  packed cluster starting at (StartX, TopY), draw a labelled box around it,  }
{  and push TopY down past the box - ready for the next sheet's group.        }
{                                                                              }
{  Each part gets a cell sized to ITS OWN footprint, not the sheet's largest  }
{  - a uniform grid keyed to the biggest part on the sheet left fifty 0402s   }
{  each sitting in a cell sized for a connector, which just spreads the       }
{  cluster out instead of grouping it. Packing left-to-right and wrapping     }
{  when a row would run past cMaxRowSpanMM (like text wrapping, not a grid)   }
{  keeps small parts tight against their neighbours.                          }
{                                                                              }
{  MoveToXY places the footprint's REFERENCE POINT, which is not generally    }
{  its bounding-box centre - fine for a cell many times the part's size, but  }
{  wrong once cells are sized to the part itself, since the part can then     }
{  land off-centre in its own cell and clip the next one. So each move is a   }
{  measure-and-correct pair: move once, read back where the bounding box      }
{  actually landed, then move again by the difference - the same trick        }
{  BuildPanel uses to seat the embedded board array exactly on (OX, OY)       }
{  rather than trust what MoveToXY's anchor turns out to be.                  }
{..............................................................................}
{                                                                              }
{  Seen holds every designator an earlier sheet already claimed: a part      }
{  whose sub-parts sit on two sheets stays in the first sheet's group rather  }
{  than being pulled again into the next one. Returns the number of          }
{  footprints actually moved, not merely found.                               }
{..............................................................................}
Function ClusterSheet(Board : IPCB_Board; Designators : TStringList;
                      Seen : TStringList;
                      StartX : TCoord; Var TopY : TCoord;
                      SheetLabel : String; LabelLayer : TLayer;
                      Var Report : String) : Integer;
Var
    Comps          : Array[0..cMaxComps - 1] Of IPCB_Component;
    Names          : Array[0..cMaxComps - 1] Of String;
    N, i, Moved    : Integer;
    Comp           : IPCB_Component;
    CW, CH         : TCoord;
    Gap            : TCoord;
    MaxSpan        : TCoord;
    RowX, RowTop, RowH : TCoord;
    GroupRight, GroupBottom : TCoord;
    CX, CY         : TCoord;
    DX, DY         : TCoord;
    R              : TCoordRect;
    BoxX1, BoxY1, BoxX2, BoxY2 : TCoord;
Begin
    N      := 0;
    Moved  := 0;
    Result := 0;
    For i := 0 To Designators.Count - 1 Do
    Begin
        If Seen.IndexOf(Designators[i]) >= 0 Then
            Report := Report + '  - ' + Designators[i] + ' (' + SheetLabel +
                      ': also on an earlier sheet, left in that sheet''s group)' + #13#10
        Else
        Begin
            Seen.Add(Designators[i]);
            Comp := Board.GetPcbComponentByRefDes(Designators[i]);
            If Comp = Nil Then
                Report := Report + '  - ' + Designators[i] + ' (' + SheetLabel +
                          ': no footprint on the PCB)' + #13#10
            Else If N < cMaxComps Then
            Begin
                Comps[N] := Comp;
                Names[N] := Designators[i];
                Inc(N);
            End;
        End;
    End;

    If N = 0 Then Exit;

    Gap        := MM(cCellGapMM);
    MaxSpan    := MM(cMaxRowSpanMM);
    RowX       := StartX;
    RowTop     := TopY;
    RowH       := 0;
    GroupRight := StartX;

    // ---- pack + move every footprint into its own cell ----
    // BeginModify/EndModify MUST be a matched pair or the object - and with it
    // the whole document - is left refusing further edits. MoveToXY throwing
    // for even one component (locked, room-constrained, whatever) used to skip
    // straight past EndModify with no bracket around it; that dangling
    // BeginModify was reproduced as "the PCB doc won't close or accept edits"
    // after a run that otherwise completed and showed its summary. EndModify
    // now lives in a Finally so it fires whether or not MoveToXY succeeds, and
    // a failure on one footprint is reported and skipped rather than aborting
    // the sheet.
    PCBServer.PreProcess;
    Try
        For i := 0 To N - 1 Do
        Begin
            If Not ComponentSize(Comps[i], CW, CH) Then
            Begin
                CW := MM(cDefaultCellMM);
                CH := MM(cDefaultCellMM);
            End;

            // wrap like text, not a grid: only once something is already on
            // the row, so one oversized part never gets stuck in an infinite
            // wrap against an empty row.
            If (RowX > StartX) And (RowX + CW > StartX + MaxSpan) Then
            Begin
                RowX   := StartX;
                RowTop := RowTop - RowH - Gap;
                RowH   := 0;
            End;

            CX := RowX + CW Div 2;
            CY := RowTop - CH Div 2;

            Try
                PCBServer.SendMessageToRobots(Comps[i].I_ObjectAddress, c_Broadcast,
                                              PCBM_BeginModify, c_NoEventData);
                Try
                    Comps[i].MoveToXY(CX, CY);
                    // measure-and-correct: MoveToXY's anchor is not the bbox
                    // centre, so read back where the box actually landed and
                    // walk it the remaining distance. A read/correct failure
                    // here is not treated as a failed move - the part is
                    // already sitting near its cell, just not perfectly
                    // centred.
                    Try
                        R  := Comps[i].BoundingRectangle;
                        DX := CX - (R.x1 + R.x2) Div 2;
                        DY := CY - (R.y1 + R.y2) Div 2;
                        If (DX <> 0) Or (DY <> 0) Then
                            Comps[i].MoveToXY(CX + DX, CY + DY);
                    Except
                    End;
                    // Selected only so the final zoom can frame the result;
                    // the whole board is deselected again after the zoom.
                    Comps[i].Selected := True;
                    Inc(Moved);
                Finally
                    PCBServer.SendMessageToRobots(Comps[i].I_ObjectAddress,
                                                  c_Broadcast, PCBM_EndModify,
                                                  c_NoEventData);
                End;
            Except
                Report := Report + '  - ' + Names[i] + ' (' + SheetLabel +
                          ': could not be moved, left where it was)' + #13#10;
            End;

            RowX := RowX + CW + Gap;
            If RowX - Gap > GroupRight Then GroupRight := RowX - Gap;
            If CH > RowH Then RowH := CH;
        End;
    Finally
        PCBServer.PostProcess;
    End;

    Result := Moved;
    GroupBottom := RowTop - RowH;

    // ---- box + label, decorative only: never worth losing the move over ----
    Try
        BoxX1 := StartX - Gap;
        BoxY1 := GroupBottom - Gap;
        BoxX2 := GroupRight + Gap;
        BoxY2 := TopY + Gap;

        AddLine(Board, LabelLayer, BoxX1, BoxY1, BoxX2, BoxY1, MM(0.15));
        AddLine(Board, LabelLayer, BoxX2, BoxY1, BoxX2, BoxY2, MM(0.15));
        AddLine(Board, LabelLayer, BoxX2, BoxY2, BoxX1, BoxY2, MM(0.15));
        AddLine(Board, LabelLayer, BoxX1, BoxY2, BoxX1, BoxY1, MM(0.15));

        AddText(Board, LabelLayer, BoxX1, BoxY2 + MM(0.8),
                SheetLabel, MM(1.5), MM(0.2));

        TopY := BoxY1 - MM(cGroupGapMM);
    Except
        Report := Report + '  - ' + SheetLabel + ': group box/label failed' + #13#10;
        TopY := GroupBottom - MM(cGroupGapMM) - Gap;
    End;
End;


{..............................................................................}
{  Entry point.                                                               }
{..............................................................................}
Procedure RunSchematicGroupper;
Var
    Project      : IProject;
    Doc          : IDocument;
    PCBPath      : String;
    PCBCount     : Integer;
    i            : Integer;
    Board        : IPCB_Board;
    PCBDoc       : IServerDocument;
    SchDoc2      : IServerDocument;
    SchDoc       : ISch_Document;
    // ISch_Iterator is not confirmed to exist as a declarable type on this
    // build (unlike ISch_Document/ISch_Component, it never turned up in the
    // DLL scan) - Variant sidesteps that guess since DelphiScript resolves
    // interface method calls by name at run time regardless of the static
    // declared type.
    Iterator     : Variant;
    IterGuard    : Integer;
    SComp        : ISch_Component;
    Designators  : TStringList;
    Seen         : TStringList;
    LabelLayer   : TLayer;
    MLayer       : IPCB_LayerObject;
    BX1, BY1, BX2, BY2 : TCoord;
    StartX, TopY : TCoord;
    SheetLabel   : String;
    SheetsUsed, SheetsEmpty, TotalPlaced, Placed : Integer;
    Report       : String;
    Breakdown    : String;
Begin
    // ---------- 1. project + the one PCB document in it ----------
    Project := GetWorkspace.DM_FocusedProject;
    If Project = Nil Then
    Begin
        ShowMessage('No project is focused. Open the project this schematic ' +
                    'and PCB belong to, then try again.');
        Exit;
    End;

    PCBPath  := '';
    PCBCount := 0;
    For i := 0 To Project.DM_LogicalDocumentCount - 1 Do
    Begin
        Doc := Project.DM_LogicalDocuments(i);
        If Doc.DM_DocumentKind = 'PCB' Then
        Begin
            PCBPath := Doc.DM_FullPath;
            Inc(PCBCount);
        End;
    End;

    If PCBCount <> 1 Then
    Begin
        ShowMessage('Could not find exactly one PCB document in this project ' +
                    '(found ' + IntToStr(PCBCount) + '). This script expects a ' +
                    'single-board project.');
        Exit;
    End;

    // Opening an already-open document just brings it to front - safe to call
    // unconditionally, whether or not the PCB was already the active document.
    PCBDoc := Client.OpenDocument('PCB', PCBPath);
    If PCBDoc = Nil Then
    Begin
        ShowMessage('Could not open the project''s PCB document.');
        Exit;
    End;
    Client.ShowDocument(PCBDoc);

    Board := PCBServer.GetCurrentPCBBoard;
    If Board = Nil Then
    Begin
        ShowMessage('Could not get the current PCB board.');
        Exit;
    End;

    If Not BoardBBox(Board, BX1, BY1, BX2, BY2) Then
    Begin
        ShowMessage('Could not read the board outline (does this board have ' +
                    'one drawn?).');
        Exit;
    End;

    If Not ConfirmNoYes('This will move every footprint on the board that ' +
                        'matches a schematic component - grouping each ' +
                        'schematic sheet''s parts into its own labelled ' +
                        'cluster in the staging area to the right of the ' +
                        'board outline.' + #13#10 + #13#10 +
                        'Anything already placed on the board gets pulled off ' +
                        'it too, since matching is by designator alone, not by ' +
                        'current position.' + #13#10 + #13#10 +
                        'Every move is its own undo step, so reverting with ' +
                        'Ctrl+Z takes many presses. Save the board first: ' +
                        'closing it without saving is the quickest full ' +
                        'revert.' + #13#10 + #13#10 +
                        'Continue?') Then Exit;

    // ---------- 2. spare mechanical layer for the group boxes/labels ----------
    // MechanicalLayerEnabled only makes the layer exist in the stack - it can
    // still come up hidden in the current view. LayerIsDisplayed is the
    // separate visibility flag that actually shows it by default.
    LabelLayer := LayerUtils.MechanicalLayer(cLabelLayerNo);
    Try
        MLayer := Board.LayerStack_V7.LayerObject_V7(LabelLayer);
        If MLayer <> Nil Then
        Begin
            MLayer.MechanicalLayerEnabled := True;
            MLayer.Name := 'Grouping';
        End;
        Board.LayerIsDisplayed[LabelLayer] := True;
    Except
        // boxes/labels just land on the mechanical layer unnamed/hidden; not fatal
    End;

    // Layer colour is not a per-document property in Altium - it is a PCB
    // editor PREFERENCE, set through Pcb:SetupPreferences with a
    // MechanicalNColor parameter (N = 1..16 only). MLayer.Color and
    // Board.LayerColors_V7[...] both compiled as "undeclared identifier" -
    // this is the one confirmed working mechanism, taken directly from
    // Altium's own shipped pcbcolor.pas example rather than guessed from a
    // DLL string. Trade-off worth knowing: this changes what Mechanical 16
    // displays as EVERY time you open ANY board in this copy of Altium, not
    // just this document - it is an application preference, not board data.
    Try
        ResetParameters;
        AddStringParameter('Mechanical' + IntToStr(cLabelLayerNo) + 'Color',
                           cLabelColor);
        RunProcess('Pcb:SetupPreferences');
    Except
        // not fatal - the layer is still enabled, named, and visible either way
    End;

    ResetParameters;
    AddStringParameter('Scope', 'All');
    RunProcess('PCB:DeSelect');

    StartX := BX2 + MM(cStagingGapMM);
    TopY   := BY2;

    SheetsUsed  := 0;
    SheetsEmpty := 0;
    TotalPlaced := 0;
    Report      := '';
    Breakdown   := '';

    // Designators already claimed by an earlier sheet (see ClusterSheet).
    Seen := TStringList.Create;
    Seen.Sorted     := True;
    Seen.Duplicates := dupIgnore;
    Try

    // ---------- 3. one cluster per schematic sheet ----------
    // PCBServer.PreProcess/PostProcess is NOT held open across this whole loop
    // on purpose: it interleaves Client.OpenDocument('SCH', ...) / ShowDocument
    // calls that switch the active editor away from the PCB entirely, and a
    // PCB edit transaction spanning a document switch like that is untested
    // territory. ClusterSheet opens its own PreProcess/PostProcess bracket
    // narrowly around just its own PCB-side moves instead.
    //
    // No Continue/Break here - DelphiScript support for them is unconfirmed,
    // and per NOTES.md a construct the interpreter rejects drops the whole
    // script from Run Script with no error, not just this loop. Plain
    // nested If/Else reaches the same result and is standard Pascal.
    For i := 0 To Project.DM_LogicalDocumentCount - 1 Do
    Begin
        Doc := Project.DM_LogicalDocuments(i);
        If Doc.DM_DocumentKind = 'SCH' Then
        Try
            SchDoc2 := Client.OpenDocument('SCH', Doc.DM_FullPath);
            If SchDoc2 = Nil Then
                Report := Report + '  - ' + ExtractFileName(Doc.DM_FullPath) +
                          ': could not open' + #13#10
            Else
            Begin
                Client.ShowDocument(SchDoc2);
                SchDoc := SchServer.GetCurrentSchDocument;

                If SchDoc = Nil Then
                    Report := Report + '  - ' + ExtractFileName(Doc.DM_FullPath) +
                              ': did not load as a schematic' + #13#10
                Else
                Begin
                    Designators := TStringList.Create;
                    Try
                        Designators.Sorted     := True;
                        Designators.Duplicates := dupIgnore;

                        Iterator := SchDoc.SchIterator_Create;
                        Try
                            Iterator.AddFilter_ObjectSet(MkSet(eSchComponent));
                            SComp := Iterator.FirstSchObject;
                            IterGuard := 0;
                            // IterGuard is a circuit breaker, not an expected
                            // limit: NextSchObject on a live sheet should
                            // terminate on its own, but Iterator is declared
                            // Variant (see note above) since ISch_Iterator was
                            // not confirmed to exist as a type on this build,
                            // and a late-bound call that never advances would
                            // otherwise spin forever with the document held
                            // open the whole time.
                            While (SComp <> Nil) And (IterGuard < 100000) Do
                            Begin
                                If SComp.Designator <> Nil Then
                                    Designators.Add(SComp.Designator.Text);
                                SComp := Iterator.NextSchObject;
                                Inc(IterGuard);
                            End;
                        Finally
                            SchDoc.SchIterator_Destroy(Iterator);
                        End;

                        SheetLabel := ExtractFileName(Doc.DM_FullPath);

                        If Designators.Count = 0 Then
                            Inc(SheetsEmpty)
                        Else
                        Begin
                            Placed := ClusterSheet(Board, Designators, Seen,
                                                   StartX, TopY, SheetLabel,
                                                   LabelLayer, Report);
                            If Placed > 0 Then
                            Begin
                                Inc(SheetsUsed);
                                TotalPlaced := TotalPlaced + Placed;
                                Breakdown := Breakdown + '  - ' + SheetLabel +
                                             ': ' + IntToStr(Placed) + ' of ' +
                                             IntToStr(Designators.Count) +
                                             ' moved' + #13#10;
                            End
                            Else
                                Inc(SheetsEmpty);
                        End;
                    Finally
                        Designators.Free;
                    End;
                End;
            End;
        Except
            Report := Report + '  - ' + ExtractFileName(Doc.DM_FullPath) +
                      ': failed, skipped' + #13#10;
        End;
    End;
    Finally
        Seen.Free;
    End;

    // ---------- 4. back to the PCB, fit the result ----------
    // Everything moved is still selected, which is what lets PCB:Zoom frame
    // it. Deselect afterwards: left selected, every cluster from every sheet
    // would move together, so each can be picked up on its own instead.
    Try
        Client.ShowDocument(PCBDoc);
        ResetParameters;
        AddStringParameter('Action', 'Selected');
        RunProcess('PCB:Zoom');
        ResetParameters;
        AddStringParameter('Scope', 'All');
        RunProcess('PCB:DeSelect');
        Board.ViewManager_UpdateLayerTabs;
        Board.GraphicalView_ZoomRedraw;
    Except
    End;

    If Report <> '' Then
        Report := #13#10 + #13#10 + 'Problems:' + #13#10 + Report;

    ShowMessage('Sheet grouping done.' + #13#10 + #13#10 +
                'Sheets grouped : ' + IntToStr(SheetsUsed) + #13#10 +
                'Sheets skipped : ' + IntToStr(SheetsEmpty) +
                ' (no components, or none found on the PCB)' + #13#10 +
                'Footprints moved: ' + IntToStr(TotalPlaced) + #13#10 + #13#10 +
                Breakdown +
                'Boxes/labels are on Mechanical ' + IntToStr(cLabelLayerNo) +
                ' (''Grouping'', set yellow) - delete that layer''s objects ' +
                'once you are done placing. Note: the yellow is an Altium ' +
                'preference for Mechanical ' + IntToStr(cLabelLayerNo) +
                ', not something stored in this board - it will show up ' +
                'that colour in other projects too.' + #13#10 + #13#10 +
                'To move a group, drag a selection window around its box. ' +
                'To revert everything, close the board without saving; ' +
                'Ctrl+Z works too but takes one press per move.' +
                Report);
End;


End.
