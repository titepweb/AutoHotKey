#Persistent
#SingleInstance Force
SetWorkingDir, %A_ScriptDir%

; TODO: Find the right place to put this.
	FileDelete, RawData.csv
	; TODO: Make headers

FileInstall, Clear.ico, Clear.ico
FileInstall, Eye.ico, Eye.ico
FileInstall, Record.ico, Record.ico
FileInstall, Stop.ico, Stop.ico

InitTray()

; Testing environment.
if (false)
{
	InitGlobals(false)
	InitGUI()

	RunUnitTests()

	Tooltip Saving...
	g_vRawData.Save()
	Tooltip
	return
}

InitGlobals()
InitGUI()

return

LeapMsgHandler(sMsg, ByRef rLeapData, ByRef rasGestures, ByRef rsOutput)
{
	global g_vMetrics, g_vUnitsInfo, g_vRawData, g_sUnits, g_iHands_c, g_s3DParse_c, g_sPalmMetricsParse_c, g_iCurSecForRawData
	static s_bIsFirstCallWithData := true, s_iLastSecForRawData
		, s_vPalmInfo := {Hand1:{TimeStartOffset:0, TotalTimeVisible:0, m_vPrevSpeed:{X:0, Y:0, Z:0}}, Hand2:{}} ; Hand2 should be identical to Hand1, not explicitly settings vars to reduce cloning.

	; Metrics needed:
		; 1. Total path distance travelled. - Done.
		; 2. Speed. - Done.
		; 3. Acceleration. - Difference in velocity between two frames. Units are: units per-second per-second (i.e. 1 m/s2).
		; 4. Motion smoothness. -
		; 5. Average distance between hands. - Done, but not tested. Using Trans, but maybe should compare Hand1X-Hand2X.

	; If no hands are present, there is no data to process.
	if (!rLeapData.HasKey("Hand1"))
		return

	; For the very first frame, we have to make certain adjustments so that time-weighted metrics don't get skewed.
	if (s_bIsFirstCallWithData) ; On the first call, we have to force the total to be 1 in order for averaging to be right.
	{
		s_vPalmInfo.Hand1.TimeStartOffset := rLeapData.Hand1.TimeVisible
		s_vPalmInfo.Hand2.TimeStartOffset := rLeapData.Hand2.TimeVisible
		s_vPalmInfo.Hand1.TotalTimeVisible := 0.001 ; ms
		s_vPalmInfo.Hand2.TotalTimeVisible := 0.001
		iTimeSinceLastCall_Hand1 := 0.001
		iTimeSinceLastCall_Hand2 :=0.001
	}
	else
	{
		Loop, %g_iHands_c% ; Set data on both hands.
		{
			sHandAsSec := "Hand" A_Index
			iTimeVisible := rLeapData[sHandAsSec].TimeVisible - s_vPalmInfo[sHandAsSec].TimeStartOffset

			if (A_Index == 2 && !rLeapData.HasKey(sHandAsSec))
			{
				; If hand2 has disappeared but we have tracked it before, just act as if TotalTimeVisible was never touched...
					; but then we'll need to offset the time again, right?
				if (s_vPalmInfo[sHandAsSec].TotalTimeVisible == A_Blank)
				{
					iTimeSinceLastCall_Hand%A_Index% := 1
					s_vPalmInfo[sHandAsSec].TotalTimeVisible := 1
					continue
				}
				else iTimeVisible := s_vPalmInfo[sHandAsSec].TotalTimeVisible
			}

			; Set the times at previous call before resetting TotalTimeVisible.
			iTimeVisibleAtPrevCall := s_vPalmInfo[sHandAsSec].TotalTimeVisible
			iTimeSinceLastCall_Hand%A_Index% := iTimeVisible - iTimeVisibleAtPrevCall

			; Now reset TotalTimeVisible.
			s_vPalmInfo[sHandAsSec].TotalTimeVisible := iTimeVisible
		}
	}

	g_iCurSecForRawData++
	if (!g_vRawData.AddSection(g_iCurSecForRawData, "", "", sError)) ; we'll notify about the problem here.
		Msgbox 8192,, An error occurred. Please contact aatozb@gmail.com in order to fix this. Technical details are outlined below.`n`n%sError%
	sRawHeaders := "TimeStamp (ms),"
	sRawData := s_vPalmInfo["Hand1"].TotalTimeVisible ","

	if (s_bIsFirstCallWithData)
	{
		g_vRawData[g_iCurSecForRawData].TimeStartOffset_Hand1 := s_vPalmInfo.Hand1.TimeStartOffset
		g_vRawData[g_iCurSecForRawData].TimeStartOffset_Hand2 := s_vPalmInfo.Hand2.TimeStartOffset
	}

	; Perform some sanity checks for our time-weighted vars.
	;~ if (!iTimeSinceLastFrame)
		;~ FatalErrorMsg("Error: There is an issue with calculating the time since the last frame " iTimeSinceLastFrame)
	;~ if (iTotalTimeElapsed == 0)
		;~ FatalErrorMsg("Error: There is an issue with the time-weighting denominator.")
	;~ else if (iTimeSinceLastFrame > iTotalTimeElapsed)
		;~ FatalErrorMsg("Error: There is an issue with the time-weighting numerator.")

	iUnitConversionFactor := g_vUnitsInfo[g_sUnits].FromMM

	; Loop over all hands.
	Loop, %g_iHands_c%
	{
		iHand := A_Index
		sHandAsSec := "Hand" iHand

		; 3D metrics.
		s .= "`nMetrics for hand " iHand "`n"
		Loop, Parse, g_s3DParse_c, |
		{
			sXYZ := A_LoopField
			s .= "---" A_LoopField "`n"

			; Distance traveled.
			sIniKey := "DistanceTraveled" sXYZ
			sMetricKey := "Trans" sXYZ
			IncVarInMetrics(rLeapData, sHandAsSec, sMetricKey, sHandAsSec, sIniKey, true, iVar)

			sLabel := "Distance traveled " sXYZ
			s .= "------" sLabel ": " g_vMetrics[sHandAsSec][sIniKey] * iUnitConversionFactor " " g_sUnits "`n"
			g_vRawData.AddKey(g_iCurSecForRawData, sIniKey, iVar, sError)
			if (s_bIsFirstCallWithData)
				sRawHeaders .= sLabel ","
			sRawData .= iVar ","

			; TODO: Make functions out of these because there is too much cloning.
			
			; Time-weighted average speed.
			sMetricKey := "WgtAvgSpeed" sXYZ
			sLeapKey := "Velocity" sXYZ

			iPrevTimeWgtSpeed := g_vMetrics[sHandAsSec][sMetricKey]
			TimeWgtVarInMetrics(rLeapData, sHandAsSec, sLeapKey, sHandAsSec, sMetricKey
				, true, iTimeSinceLastCall_Hand%iHand%, s_vPalmInfo[sHandAsSec].TotalTimeVisible, iVar)

			sCurSpeedLabel := "Current speed: "
			s .= "------" sCurSpeedLabel (abs(rLeapData[sHandAsSec][sLeapKey]) * iUnitConversionFactor) " " g_sUnits "/s`n"
			sRawData .= rLeapData[sHandAsSec][sLeapKey] ","
			sAvgSpeedLabel := "Avg. speed: "
			s .= "------" sAvgSpeedLabel (iVar * iUnitConversionFactor) " " g_sUnits "/s`n"
			g_vRawData.AddKey(g_iCurSecForRawData, sMetricKey, iVar)
			sRawData .= iVar ","
			if (s_bIsFirstCallWithData)
			{
				sRawHeaders .= sCurSpeedLabel ","
				sRawHeaders .= sAvgSpeedLabel ","
			}

			; Time-weighted average acceleration.
			; TODO: See if manually time-weighting acceleration is any different than
			; subtracting this weighted-average velocity from the previous one.
			iThisTimeWgtSpeed := iVar
			; Calc. Accelerations.
			iTimeWgtAccel := iThisTimeWgtSpeed - iPrevTimeWgtSpeed
			iCurrentAccel := rLeapData[sHandAsSec][sLeapKey] - s_vPalmInfo[sHandAsSec].m_vPrevSpeed[A_LoopField]

			;~ sMetricKey := "WgtAvgAccel" sXYZ
			;~ sLeapKey := "Velocity" sXYZ

			;~ TimeWgtVarInMetrics(rLeapData, sHandAsSec, sLeapKey, sHandAsSec, sMetricKey
				;~ , true, iTimeSinceLastCall_Hand%iHand%, s_vPalmInfo[sHandAsSec].TotalTimeVisible, iVar)

			sCurrentAccelLabel := "Current avg. acceleration: "
			s .= "------" sCurrentAccelLabel (iCurrentAccel * iUnitConversionFactor) " " g_sUnits "/s2`n"
			g_vRawData.AddKey(g_iCurSecForRawData, "RawAccel" A_LoopField, iCurrentAccel)
			sRawData .= iCurrentAccel ","
			sAvgAccelLabel := "Avg. acceleration: "
			s .= "------" sAvgAccelLabel (iTimeWgtAccel * iUnitConversionFactor) " " g_sUnits "/s2`n"
			g_vRawData.AddKey(g_iCurSecForRawData, "WgtAvgAccel" A_LoopField, iTimeWgtAccel)
			sRawData .= iTimeWgtAccel ","
			g_vMetrics[sHandAsSec]["WgtAvgAccel" A_LoopField] := iTimeWgtAccel
			if (s_bIsFirstCallWithData)
			{
				sRawHeaders .= sCurrentAccelLabel ","
				sRawHeaders .= sAvgAccelLabel ","
			}

			s_vPalmInfo[sHandAsSec].m_vPrevSpeed[A_LoopField] := rLeapData[sHandAsSec]["Velocity" sXYZ]
		}

		; Palm metrics.
		s .= "`n"
		Loop, Parse, g_sPalmMetricsParse_c, |
		{
			sMetricKey := "WgtAvg" A_LoopField
			sLeapKey := A_LoopFIeld
			TimeWgtVarInMetrics(rLeapData, sHandAsSec, sLeapKey, sHandAsSec, sMetricKey, false, iTimeSinceLastCall_Hand%iHand%, s_vPalmInfo[sHandAsSec].TotalTimeVisible, iVar)

			sCurrentLabel := "Current " sLeapKey
			s .= "---" sCurrentLabel ": " (rLeapData[sHandAsSec][sLeapKey]) Chr(176) "`n" ; Note: degrees, so don't use iUnitConversionFactor.
			sRawData .= rLeapData[sHandAsSec][sLeapKey] ","

			sAvgLabel := "---Avg. " sLeapKey
			s .= sAvgLabel ": " iVar Chr(176) "`n"
			g_vRawData.AddKey(g_iCurSecForRawData, sIniKey, iVar)
			sRawData .= iVar ","
			if (s_bIsFirstCallWithData)
			{
				sRawHeaders .= "Current " sLeapKey ","
				sRawHeaders .= "Avg. " sLeapKey ","
			}
		}
	}

	; Avgerage distance between palms.
	s .= "`nOther data`n"
	Loop, Parse, g_s3DParse_c, |
	{
		sLeapSec := "Header"
		sLeapKey := "PalmDiff" A_LoopFIeld
		sMetricSec := "Other"
		sMetricKey := "WgtAvgDistFromPalms" A_LoopField
		; This is a special case since the keys in the header are not always persent.
		if (rLeapData[sLeapSec].HasKey(sLeapKey))
			TimeWgtVarInMetrics(rLeapData, sLeapSec, sLeapKey, sMetricSec, sMetricKey, true, iTimeSinceLastCall_Hand1, s_vPalmInfo.Hand1.TotalTimeVisible, iVar)
		else iVar := g_vMetrics[sMetricSec][sMetricKey]

		s .= "---Avg. Distance Betw. Hand " A_LoopFIeld ": " (iVar * iUnitConversionFactor) "`n"
		g_vRawData.AddKey(g_iCurSecForRawData, sLeapKey, iVar)
		sRawHeaders .= "Avg. Distance Betw. Hand " A_LoopFIeld ","
		sRawData .= iVar ","
	}

	SurgeryWatcher_OutputToGUI(s)

	if (s_bIsFirstCallWithData)
		FileAppend, %sRawHeaders%`n, RawData.csv
	FileAppend, %sRawData%`n, RawData.csv

	s_bIsFirstCallWithData := false
	s_iLastSecForRawData := g_iCurSecForRawData
	return
}
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
/*
	Author: Verdlin
	Function: IncVarInMetrics
		Purpose: To locaize logic of adding metrics to our metrics db.
	Parameters
		rLeapData
		sLeapSec: A (possibly) valid section in rLeapData
		sLeapKey: A valid key in rLeapData
		sMetricSec: A valid section in g_vMetrics (usually the same as sLeapSec)
		sMetricKey: A valid section in g_vMetrics (usually the same as sLeapKey)
		bUseAbsVal: Use aboslute value of variable?
		riVar="": Passed out var retrieved from rLeapData
*/
IncVarInMetrics(ByRef rLeapData, sLeapSec, sLeapKey, sMetricSec, sMetricKey, bUseAbsVal, ByRef riVar="")
{
	global
	riVar := 0

	; Validate all sections and keys.
	ValidateLeapAndMetricSecsAndKeys(rLeapData, sLeapSec, sLeapKey, sMetricSec, sMetricKey)

	riVar := rLeapData[sLeapSec][sLeapKey]

	if (riVar != A_Blank)
	{
		if (bUseAbsVal)
			riVar := abs(riVar)

		g_vMetrics[sMetricSec][sMetricKey] += riVar
	}
	else riVar := g_vMetrics[sMetricSec][sMetricKey]

	return
}
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
/*
	Author: Verdlin
	Function: TimeWgtVarInMetrics
		Purpose: Handles general logic for time-weighting a variable tracking in our Leap procedures.
	Parameters
		rLeapData
		sLeapSec: A (possibly) valid section in rLeapData
		sLeapKey: A valid key in rLeapData
		sMetricSec: A valid section in g_vMetrics (usually the same as sLeapSec)
		sMetricKey: A valid section in g_vMetrics (usually the same as sLeapKey)
		bUseAbsVal: Use aboslute value of variable?
		iTimeMultiplier_Num: To multiply numerator by
		iTotalTime_Denom
		riVar="": Passed out var retrieved from rLeapData
*/
TimeWgtVarInMetrics(ByRef rLeapData, sLeapSec, sLeapKey, sMetricSec, sMetricKey, bUseAbsVal, iTimeMultiplier_Num, iTotalTime_Denom, ByRef riVar="")
{
	global
	riVar := 0

	; Validate all sections and keys.
	ValidateLeapAndMetricSecsAndKeys(rLeapData, sLeapSec, sLeapKey, sMetricSec, sMetricKey)

	iVar := rLeapData[sLeapSec][sLeapKey]

	if (iVar != A_Blank)
	{
		if (bUseAbsVal)
			iVar := abs(iVar)

		g_vRawData[g_iCurSecForRawData][sLeapKey "_NonWgted"] := iVar
		g_vRawData[g_iCurSecForRawData][sLeapKey "_Num"] := iTimeMultiplier_Num

		iVar *= iTimeMultiplier_Num ; Time-weight var num.
		; Don't /div 0!
		if (iTotalTime_Denom == 0)
			iTotalTime_Denom := 1

		; In order to inc the time-weighted var, we need to retrieve the previous, aggregated raw (non-weighted) val.
		iPrevAggRawVal := g_vMetrics[sMetricSec][sMetricKey] * (iTotalTime_Denom - iTimeMultiplier_Num)

		g_vRawData[g_iCurSecForRawData][sLeapKey "_Denom"] := iTotalTime_Denom
		g_vRawData[g_iCurSecForRawData][sLeapKey "_PrevAggRawVal"] := iPrevAggRawVal

		; Divide the aggregated vars by the total time elapsed.
		g_vMetrics[sMetricSec][sMetricKey] := (iVar + iPrevAggRawVal) / iTotalTime_Denom ; Here's where we time-weight denom.
		g_vRawData[g_iCurSecForRawData][sLeapKey "_FinalVal"] := g_vMetrics[sMetricSec][sMetricKey]
	}

	riVar := g_vMetrics[sMetricSec][sMetricKey]

	return
}
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
/*
	Author: Verdlin
	Function: ValidateLeapAndMetricSecsAndKeys
		Purpose: Effectively catches bugs in script if we try to use invalid sections or keys for data storage.
	Parameters
		rLeapData
		sLeapSec: A section in rLeapData
		sLeapKey: A key in rLeapData
		sMetricSec: A section in g_vMetrics (usually the same as sLeapSec)
		sMetricKey: A section in g_vMetrics (usually the same as sLeapKey)
*/
ValidateLeapAndMetricSecsAndKeys(ByRef rLeapData, sLeapSec, sLeapKey, sMetricSec, sMetricKey)
{
	global g_vMetrics

	; It's ok if Hand1 is present but Hand2 is not; in those cases, we just use 0.
	; Key must be present in header OR Hand1. If sLeapSec is Hand2, that is ok because keys are identical between both hands.
	; sMetricSec and sMetricKey must be valid.
	bMetricHasSec := g_vMetrics.HasKey(sMetricSec)
	bMetricHasKey := g_vMetrics[sMetricSec].HasKey(sMetricKey)
	if (!((rLeapData.Header.HasKey(sLeapKey) || (rLeapData.HasKey("Hand1") && rLeapData["Hand1"].HasKey(sLeapKey)))
			&& bMetricHasSec && bMetricHasKey))
	{
		FatalErrorMsg("Error: Program is trying to retrieve data from the Leap engine using invalid sections or keys`n`nLeap data section:`t" sLeapSec "(" rLeapData.Header.HasKey(sLeapKey) "-" rLeapData.HasKey("Hand1") "-" rLeapData["Hand1"].HasKey(sLeapKey) ")`nLeap data key:`t" sLeapKey "(" rLeapData[sLeapSec].HasKey(sLeapKey) ")`nMetric data section:`t" sMetricSec "(" bMetricHasSec ")`nMetric data key:`t" sMetricKey "(" bMetricHasKey ")")
	}

	return
}
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
/*
	Author: Verdlin
	Function: InitGUI
		Purpose: Set up the main GUI
	Parameters
		
*/
InitGUI()
{
	global

	GUI, SurgeryWatcher_:New, MinSize Resize, Surgery Watcher

	; ---Menus---

	; File
	Menu, SurgeryWatcher_FileMenu, Add, E&xport...`tCtrl + Shift + E, SurgeryWatcher_Export
	Menu, SurgeryWatcher_FileMenu, Icon, E&xport...`tCtrl + Shift + E, AutoLeap\Save As.ico,, 16
	Menu, SurgeryWatcher_FileMenu, Add, E&xit`tAlt + F4, SurgeryWatcher_GUIClose
	Menu, SurgeryWatcher_FileMenu, Icon, E&xit`tAlt + F4, AutoLeap\Exit.ico,, 16

	; Edit
	Menu, SurgeryWatcher_EditMenu, Add, &Record`tCtrl + R, SurgeryWatcher_RecordOrStop
	Menu, SurgeryWatcher_EditMenu, Icon, &Record`tCtrl + R, Record.ico,, 16

	; View
	for sec, aData in g_vUnitsInfo
	{
		aData.Menu .= "`tAlt + " A_Index
		Menu, SurgeryWatcher_ViewMenu, Add, % aData.Menu, SurgeryWatcher_UnitChange
	}
	Menu, SurgeryWatcher_ViewMenu, Check, % g_vUnitsInfo.mm.Menu ; Check Millimeters.
	g_sUnits := "mm"

	Menu, SurgeryWatcher_MainMenu, Add, &File, :SurgeryWatcher_FileMenu
	Menu, SurgeryWatcher_MainMenu, Add, &Edit, :SurgeryWatcher_EditMenu
	Menu, SurgeryWatcher_MainMenu, Add, &View, :SurgeryWatcher_ViewMenu

	GUI, Menu, SurgeryWatcher_MainMenu

	; ---Layout---

	GUI, Font, s12
	GUI, Add, Edit, x5 w400 h400 vg_vSurgeryWatcher_Output ReadOnly
	GUI, Font, s10
	; Record/Stop.
	GUI, Add, Button, % "x5 yp+" 400+g_iMSDNStdBtnSpacing " w80 h26 hwndg_hRecordBtn vg_vRecordBtn gSurgeryWatcher_RecordOrStop", S&tart
	ILButton(g_hRecordBtn, "Record.ico", 24, 24, 0)
	GUI, Add, Button, % "X" 400 - g_iMSDNStdBtnW + 6 " Yp+" 26 - g_iMSDNStdBtnH " W" g_iMSDNStdBtnW " H" g_iMSDNStdBtnH " vg_vExitBtn gSurgeryWatcher_Exit", E&xit

	GUIControl, Focus, g_vRecordBtn
	GUI, Show

	return

	SurgeryWatcher_UnitChange:
	{
		; Check one item, uncheck all others.
		for sec, aData in g_vUnitsInfo
		{
			if (A_ThisMenuItem = aData.Menu)
			{
				g_sUnits := sec
				Menu, SurgeryWatcher_ViewMenu, Check, % aData.Menu
			}
			else Menu, SurgeryWatcher_ViewMenu, Uncheck, % aData.Menu
		}

		return
	}

	SurgeryWatcher_RecordOrStop:
	{
		g_bIsRecording := !g_bIsRecording

		if (g_bIsRecording)
		{
			if (!g_vMetrics.IsEmpty() && !g_bMetricsDataWasExported)
			{
				MsgBox, 8228, Start Recording?, If you start recording`, all data from previous simulation will be removed.
				IfMsgBox Yes
				{
					InitGlobals(false) ; No need to re-init Leap.
					SurgeryWatcher_OutputToGUI("")
				}
				else
				{
					g_bIsRecording := false
					return
				}
			}

			GUIControl,, g_vRecordBtn, S&top
			ILButton(g_hRecordBtn, "Stop.ico", 24, 24, 0)
			Menu, SurgeryWatcher_EditMenu, Rename, &Record`tCtrl + R, Stop &Recording`tCtrl + R
			Menu, SurgeryWatcher_EditMenu, Icon, Stop &Recording`tCtrl + R, Record.ico,, 16
			g_vLeap.SetTrackState(true)
		}
		else
		{
			GUIControl,, g_vRecordBtn, S&tart
			ILButton(g_hRecordBtn, "Record.ico", 24, 24, 0)
			Menu, SurgeryWatcher_EditMenu, Rename, Stop &Recording`tCtrl + R, &Record`tCtrl + R
			Menu, SurgeryWatcher_EditMenu, Icon, &Record`tCtrl + R, Record.ico,, 16
			g_vLeap.SetTrackState(false)
			g_bMetricsDataWasExported := false
		}

		return
	}

	SurgeryWatcher_Export:
	{
		g_vMetrics.Save()
		FileDelete, Export.csv

		aColData := {}
		aRows := []
		; Sections are columns.
		for sec, aData in g_vMetrics
		{
			if (sec = "Other")
				continue
			bMakeHeaders := (A_Index == 2)

			; Keys are row headings.
			; values are cells.
			aColData[sec] := []
			sRow := sec
			for k, v in aData
			{
				if (bMakeHeaders)
					sHeaders .= k ","
				sRow .= "," v
			}
			aRows.Insert(sRow)
		}

		; H1,H2,H3,...
		FileAppend, `,%sHeaders%, Export.csv

		for i, v in aRows
		{
			; Row,V1,V2,V3,...
			FileAppend, `n%v%, Export.csv
		}

		Msgbox 8192,, Export has completed.`n`nSaved to: %A_WorkingDir%\Export.csv
		g_bMetricsDataWasExported := true
		return
	}

	SurgeryWatcher_GUISize:
	{
		Anchor2("SurgeryWatcher_:g_vSurgeryWatcher_Output", "xwyh", "0, 1, 0, 1")
		Anchor2("SurgeryWatcher_:g_vRecordBtn", "xwyh", "0, 0, 1, 0")
		Anchor2("SurgeryWatcher_:g_vExitBtn", "xwyh", "1, 0, 1, 0")

		return
	}

	SurgeryWatcher_GUIClose:
	{
		GUI, SurgeryWatcher_:Destroy
		return
	}

	Reload:
	SurgeryWatcher_Exit:
	{
		SurgeryWatcher_Exit()
		return
	}
}
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
/*
	Author: Verdlin
	Function: SurgeryWatcher_Exit
		Purpose: To exit gracefully.
	Parameters
		
*/
SurgeryWatcher_Exit()
{
	global
	;~ g_vLeap.OSD_PostMsg("Data is being logged...")
	;~ g_vRawData.Save() ; This will take some time

	GUI, SurgeryWatcher_:Destroy
	g_vLeap.m_bInit := true ; Since I have so much trouble getting this to freaking delete.
	g_vLeap.__Delete()
	ExitApp
	return
}
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
/*
	Author: Verdlin
	Function: SurgeryWatcher_OutputToGUI
		Purpose: To localize logic of displaying information on the GUI.
	Parameters
		s: String to output
*/
SurgeryWatcher_OutputToGUI(s)
{
	GUI, SurgeryWatcher_:Default
	GUIControl,, g_vSurgeryWatcher_Output, %s%
	return
}
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
/*
	Author: Verdlin
	Function: InitTray
		Purpose: To initialize the tray icon appropriately.
	Parameters
		
*/
InitTray()
{
	; Tray icon
	Menu, TRAY, Icon, Eye.ico,, 1

	Menu, TRAY, NoStandard
	Menu, TRAY, MainWindow ; For compiled scripts
	Menu, TRAY, Add, E&xit, SurgeryWatcher_Exit
	Menu, TRAY, Click, 1
	return
}
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
/*
	Author: Verdlin
	Function: InitGlobals
		Purpose:
	Parameters
		bInitLeap=true; I need it to be false for unit tests.
*/
InitGlobals(bInitLeap=true)
{
	global

	; http://msdn.microsoft.com/en-us/library/windows/desktop/aa511453.aspx#sizing
	g_iMSDNStdBtnW := 75
	g_iMSDNStdBtnH := 23
	g_iMSDNStdBtnSpacing := 6

	g_iHands_c := 2
	g_iCurSecForRawData := 0
	; For parsing loops within hands loop.
	g_s3DParse_c := "X|Y|Z"
	g_sPalmMetricsParse_c := "Roll|Pitch|Yaw"

	; Leap Forwarder.
	local sMetrics := "
	(LTrim
		[Other]
		WgtAvgDistFromPalmsX=0
		WgtAvgDistFromPalmsY=0
		WgtAvgDistFromPalmsZ=0

		[Hand1]
		DistanceTraveledX=0
		DistanceTraveledY=0
		DistanceTraveledZ=0
		WgtAvgSpeedX=0
		WgtAvgSpeedY=0
		WgtAvgSpeedZ=0
		WgtAvgAccelX=0
		WgtAvgAccelY=0
		WgtAvgAccelZ=0
		WgtAvgRoll=0
		WgtAvgPitch=0
		WgtAvgYaw=0

		[Hand2]
		DistanceTraveledX=0
		DistanceTraveledY=0
		DistanceTraveledZ=0
		WgtAvgSpeedX=0
		WgtAvgSpeedY=0
		WgtAvgSpeedZ=0
		WgtAvgAccelX=0
		WgtAvgAccelY=0
		WgtAvgAccelZ=0
		WgtAvgRoll=0
		WgtAvgPitch=0
		WgtAvgYaw=0
	)"
	g_vMetrics := class_EasyIni("", sMetrics)
	g_bMetricsDataWasExported := true ; because there's nothing to export when we first start.

	; Sections will be corresponding to the point in time that the frame came into being.
	; Keys will contain the frame data.
	FileDelete, RawData.ini
	g_vRawData := class_EasyIni("RawData")

	local sUnitsInfo := "
	(LTrim
		[m]
		Menu=&Meters (m)
		FromMM=0.001

		[cm]
		Menu=&Centimeters (cm)
		FromMM=0.1

		[mm]
		Menu=Mi&llimeters (mm)
		FromMM=1

		[in]
		Menu=&Inches (in)
		FromMM=0.03937008

		[ft]
		Menu=&Feet (ft)
		FromMM=0.00328084
	)"
	g_vUnitsInfo := class_EasyIni("", sUnitsInfo)

	if (bInitLeap)
	{
		g_vLeap := new AutoLeap("LeapMsgHandler")
		g_vLeap.m_vProcessor.m_bIgnoreGestures := true
		g_vLeap.SetTrackState(false)
	}

	return
}
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
/*
	Author: Verdlin
	Function: RunUnitTests
		Purpose: To ensure our calculations are valid.
	Parameters
		
*/
RunUnitTests()
{
	global g_s3DParse_c
	sLeapData := "
	(LTrim
		[Header]
		hWnd=0x0
		DataType=Update
		PalmDiffX=100
		PalmDiffY=100
		PalmDiffZ=100

		[Hand1]
		TransX=0
		TransY=0
		TransZ=0
		VelocityX=100
		VelocityY=100
		VelocityZ=100

		TimeVisible=1
		Roll=0
		Pitch=0
		Yaw=0
	)"
	vLeapData := class_EasyIni("", sLeapData)

	for k, v in vLeapData.Hand1
		vLeapData.Hand1[k] := 100
	Loop, Parse, g_s3DParse_c, |
		vLeapData.Header["Trans" A_LoopField] := 100
	vLeapData.Hand1.TimeVisible := 0
	LeapMsgHandler("", vLeapData, [], s)
	Tooltip 1
	Sleep 1000

	for k, v in vLeapData.Hand1
		vLeapData.Hand1[k] :=150
	Loop, Parse, g_s3DParse_c, |
		vLeapData.Header["Trans" A_LoopField] := 150
	vLeapData.Hand1.TimeVisible := 1001
	LeapMsgHandler("", vLeapData, [], s)
	Tooltip 2
	Sleep 1000

	for k, v in vLeapData.Hand1
		vLeapData.Hand1[k] :=200
	Loop, Parse, g_s3DParse_c, |
		vLeapData.Header["Trans" A_LoopField] := 200
	vLeapData.Hand1.TimeVisible := 2001
	LeapMsgHandler("", vLeapData, [], s)
	Tooltip 3
	Sleep 1000

	return
}
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
/*
	Author: Verdlin
	Function: FatalErrorMsg
		Purpose: It's nice to append some data to a fatal error MsgBox and then quit.
	Parameters
		sError: Error to display.
*/
FatalErrorMsg(sError)
{
	global g_vRawData, g_vLeap
	Msgbox 8192,, %sError%`n`nPlease contact aatozb@gmail.com in order to fix this.`n`nThe program will exit after this message is dismissed.

	g_vLeap.OSD_PostMsg("Data is being logged...")
	; g_vRawData serves as a kind of log.
	g_vRawData.Save()
	g_vLeap.OSD_PostMsg("Data has been saved. The application will now exit.")
	Sleep 1500

	return SurgeryWatcher_Exit()
}
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

/*
-----------------------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------DEPENDENCIES--------------------------------------------------
-----------------------------------------------------------------------------------------------------------------------------------
*/

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;; My (Verdlin) modification of Titan?s/Polythene?s anchor function: https://raw.github.com/polyethene/AutoHotkey-Scripts/master/Anchor.ahk
;;;;;;;;;;;;;; Using this one instead of Attach or Titan�s/Polythene�s Anchor v4 because this function,
;;;;;;;;;;;;;; although the parameter syntax is downright atrocious, actually works in Windows 7 and 8.
Anchor2(ctrl, a, d = false) {
static pos
sGUI := SubStr(ctrl, 1, InStr(ctrl, ":")-1)
GUI, %sGUI%:Default
ctrl := SubStr(ctrl, InStr(ctrl, ":")+1)
sig = `n%ctrl%=

If (d = 1){
draw = Draw
d=1,1,1,1
}Else If (d = 0)
d=1,1,1,1
StringSplit, q, d, `,

If !InStr(pos, sig) {
GUIControlGet, p, Pos, %ctrl%
pos := pos . sig . px - A_GUIWidth * q1 . "/" . pw - A_GUIWidth * q2 . "/"
. py - A_GUIHeight * q3 . "/" . ph - A_GUIHeight * q4 . "/"
}
StringTrimLeft, p, pos, InStr(pos, sig) - 1 + StrLen(sig)
StringSplit, p, p, /

s = xwyh
Loop, Parse, s
If InStr(a, A_LoopField) {
If A_Index < 3
e := p%A_Index% + A_GUIWidth * q%A_Index%
Else e := p%A_Index% + A_GUIHeight * q%A_Index%
d%A_LoopField% := e
m = %m%%A_LoopField%%e%
}
GUIControlGet, i, hwnd, %ctrl%
ControlGetPos, cx, cy, cw, ch, , ahk_id %i%

DllCall("SetWindowPos", "UInt", i, "Int", 0, "Int", dx, "Int", dy, "Int", InStr(a, "w") ? dw : cw, "Int", InStr(a, "h") ? dh : ch, "Int", 4)
DllCall("RedrawWindow", "UInt", i, "UInt", 0, "UInt", 0, "UInt", 0x0101) ; RDW_UPDATENOW | RDW_INVALIDATE
return
}

#Include %A_ScriptDir%\AutoLeap\AutoLeap.ahk

;~ ----------------------------------------------------------------------------------------------------------------------------------------------------------
;~ ------------------------------------------------------------DEPRECATED-------------------------------------------------------------------------------
;~ ----------------------------------------------------------------------------------------------------------------------------------------------------------

/* 
LeapMsgHandler(sMsg, ByRef rLeapData, ByRef rasGestures, ByRef rsOutput)
{
	global g_vMetrics, g_vUnitsInfo, g_vRawData, g_sUnits, g_iHands_c, g_s3DParse_c, g_sPalmMetricsParse_c
	static s_iTimeStartOffset_Hand1, s_iTimeStartOffset_Hand2, s_bIsFirstCallWithData := true, s_iTimeAtFirstFrameWithData:0

	; Metrics needed:
		; 1. Total path distance travelled. - Done
		; 2. Speed. - Done
		; 3. Acceleration. -
		; 4. Motion smoothness. -
		; 5. Average distance between hands. - Next up

	if (!s_bIsFirstCallWithData) ; TODO: See if I can remove this check -- every bit counts(?)
		iTimeSinceLastFrame := QPX(false) * 1000 ; QPX returns seconds, and me want ms.

	; If no hands are present, there is no data to process.
	; Note: We return *after* calling QPX()
	if (!rLeapData.HasKey("Hand1"))
		return

	; DO NOT USE A_TICKCOUNT; USE QPX().
	iTotalTimeElapsed := iTimeSinceLastFrame - s_iTimeAtFirstFrameWithData
	; For the very first frame, we have to make certain adjustments so that time-weighted metrics don't get skewed.
	if (s_bIsFirstCallWithData) ; On the first call, we have to force the total to be 1 in order for averaging to be right.
	{
		QPX(true) ; Start counting from here.
		s_iTimeStartOffset_Hand1 := rLeapData.Hand1.TimeVisible
		s_iTimeStartOffset_Hand2 := rLeapData.Hand2.TimeVisible
		iTotalTimeElapsed := 1
		iTimeSinceLastFrame := 1
		s_iTimeAtFirstFrameWithData := 1
	}
	else iTotalTimeElapsed -= s_iTimeStartOffset

	; Frames can come through *really* fast, so if there is zero difference, we have may have to force 1ms difference.
	; TODO: See if this is necessary now that I use QPX.
	iOrigTimeElapsed := iTotalTimeElapsed
	if (g_vRawData.HasKey(iTotalTimeElapsed))
		iTotalTimeElapsed++
	if (!g_vRawData.AddSection(iTotalTimeElapsed, "OrigTimeElap", iOrigTimeElapsed, sError)) ; we'll notify about the problem here.
		Msgbox 8192,, An error occurred. Please contact aatozb@gmail.com in order to fix this. Technical details are outlined below.`n`n%sError%

	if (s_bIsFirstCallWithData)
		g_vRawData[iTotalTimeElapsed].StartTimeOffset := s_iTimeStartOffset

	; Perform some sanity checks for our time-weighted vars.
	if (!iTimeSinceLastFrame)
		FatalErrorMsg("Error: There is an issue with calculating the time since the last frame " iTimeSinceLastFrame)
	if (iTotalTimeElapsed == 0)
		FatalErrorMsg("Error: There is an issue with the time-weighting denominator.")
	else if (iTimeSinceLastFrame > iTotalTimeElapsed)
		FatalErrorMsg("Error: There is an issue with the time-weighting numerator.")

	iUnitConversionFactor := g_vUnitsInfo[g_sUnits].FromMM

	; Loop over all hands.
	Loop, %g_iHands_c%
	{
		iHand := A_Index
		sHandAsSec := "Hand" iHand

		; If this hand isn't present, continue.
		if (!rLeapData.HasKey(sHandAsSec))
			continue

		; 3D metrics.
		s .= "Metrics for hand " iHand "`n"
		Loop, Parse, g_s3DParse_c, |
		{
			sXYZ := A_LoopField

			; Distance traveled.
			sIniKey := "DistanceTraveled" sXYZ
			sMetricKey := "Trans" sXYZ
			IncVarInMetrics(rLeapData, sHandAsSec, sMetricKey, sHandAsSec, sIniKey, true, iVar)

			s .= "   Distance Traveled " sXYZ ": " g_vMetrics[sHandAsSec][sIniKey] * iUnitConversionFactor " " g_sUnits "`n"
			g_vRawData.AddKey(iTotalTimeElapsed, sIniKey, iVar)

			; Time-weighted average speed.
			sMetricKey := "WgtAvgSpeed" sXYZ
			sLeapKey := "Velocity" sXYZ

			TimeWgtVarInMetrics(rLeapData, sHandAsSec, sLeapKey, sHandAsSec, sMetricKey, true, iTimeSinceLastFrame, iTotalTimeElapsed, iVar)

			s .= "   Current Speed " sXYZ ": " rLeapData[sHandAsSec][sLeapKey] * iUnitConversionFactor " " g_sUnits "/s`n"
			s .= "   Avg. Speed " sXYZ ": " iVar * iUnitConversionFactor " " g_sUnits "/s`n"
			g_vRawData.AddKey(iTotalTimeElapsed, sIniKey, iVar)
		}

		; Palm metrics.
		Loop, Parse, g_sPalmMetricsParse_c, |
		{
			sMetricKey := "WgtAvg" A_LoopField
			TimeWgtVarInMetrics(rLeapData, sHandAsSec, A_LoopField, sHandAsSec, sMetricKey, false, iTimeSinceLastFrame, iTotalTimeElapsed, iVar)

			s .= "   Current " A_LoopFIeld ": " rLeapData[sHandAsSec][sLeapKey] * iUnitConversionFactor " " g_sUnits "/s`n"
			s .= "   Avg. " A_LoopField ": " iVar " " g_sUnits "/s`n"
			g_vRawData.AddKey(iTotalTimeElapsed, sIniKey, iVar)
		}
	}

	SurgeryWatcher_OutputToGUI(s)

	s_bIsFirstCallWithData := false
	return
}
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


timeSinceLastCall ( http://ahkscript.org/boards/viewtopic.php?f=6&t=537 )
   Return the amount of time, in milliseconds, that has passed since you last called this function.

   id    = You may use different ID's to store different timesets. ID should be 1 and above (not 0 or negative) or a string.
   reset = If reset is 1 and id is 0, all ID's are cleared. Otherwise if reset is 1, that specific id is cleared.

   * NOTE:
   The first call is usually blank.

example:
   out:=timeSinceLastCall()
   sleep, 500
   out:=timeSinceLastCall()
output:  500
TimeSinceLastCall(id=1, reset=0)
{
   static arr:=array()
   if (reset=1)
   {
      ((id=0) ? arr:=[] : (arr[id, 0]:=arr[id, 1]:="", arr[id, 2]:=0))
      return
   }
   arr[id, 2]:=!arr[id, 2]
   arr[id, arr[id, 2]]:=A_TickCount      
   return abs(arr[id,1]-arr[id,0])
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
/*
	Author: Verdlin
	Function: RunUnitTests
		Purpose: To ensure our calculations are valid.
	Parameters
		

RunUnitTests()
{
	sLeapData := "
	(LTrim
		[Header]
		hWnd=0x0
		DataType=Update

		[Hand1]
		TransX=0
		TransY=0
		TransZ=0
		VelocityX=100
		VelocityY=100
		VelocityZ=100

		Roll=0
		Pitch=0
		Yaw=0
	)"
	vLeapData := class_EasyIni("", sLeapData)

	for k, v in vLeapData.Hand1
		vLeapData.Hand1[k] := 100
	LeapMsgHandler("", vLeapData, [], s)
	Tooltip 1
	Sleep 1000

	for k, v in vLeapData.Hand1
		vLeapData.Hand1[k] :=150
	LeapMsgHandler("", vLeapData, [], s)
	Tooltip 2
	Sleep 1000

	for k, v in vLeapData.Hand1
		vLeapData.Hand1[k] :=200
	LeapMsgHandler("", vLeapData, [], s)
	Tooltip 3
	Sleep 1000

	return
}
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
*/