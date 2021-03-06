{
  Copyright 2010-2018 Michalis Kamburelis.

  This file is part of "Castle Game Engine".

  "Castle Game Engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Castle Game Engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{$ifdef read_interface}

  { Possible touch control UI, for @link(TCastleTouchControl.TouchMode). }
  TCastleTouchCtlMode = (
    ctcmWalking, ctcmWalkWithSideRot, ctcmHeadRotation, ctcmFlyUpdown, ctcmPanXY);
  TCastleTouchPosition = (tpManual, tpLeft, tpRight);

  { Touch user interface to navigate in a 3D world.
    Shows one "lever", that can be moved up/down/left/right,
    and controls the movement while Walking or Flying.

    Usually, this control is created and used through the @link(TCastleWindowTouch)
    properties. There is no need to directly create TCastleTouchControl instance
    in this case. }
  TCastleTouchControl = class(TCastleUserInterface)
  strict private
    FTouchMode: TCastleTouchCtlMode;
    FLeverOffset: TVector2;
    FDragging: Integer; //< finger index that started drag, -1 if none
    FPosition: TCastleTouchPosition;
    FScale: Single;
    function TotalScale: Single;
    procedure SetPosition(const Value: TCastleTouchPosition);
    procedure SetScale(const Value: Single);
    function MaxOffsetDist: Integer;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Render; override;

    function FloatRect: TFloatRectangle; override;

    function Press(const Event: TInputPressRelease): boolean; override;
    function Release(const Event: TInputPressRelease): boolean; override;
    function Motion(const Event: TInputMotion): boolean; override;
    procedure SetTouchMode(const Value: TCastleTouchCtlMode);
    procedure GetSensorRotation(var X, Y, Z, Angle: Double);
    procedure GetSensorTranslation(var X, Y, Z, Length: Double);
  published
    property TouchMode: TCastleTouchCtlMode
      read FTouchMode write SetTouchMode default ctcmWalking;

    { Set position of touch control. Right now this simply sets
      the anchor using @link(TCastleUserInterface.HasHorizontalAnchor) and friends.
      Tip: Use @link(TUIContainer.UIScaling) to have the anchors automatically
      scale with screen size.

      The size of the control is set to be constant physical size,
      so it's not affected by @link(TUIContainer.UIScaling), only by
      @link(TUIContainer.Dpi). }
    property Position: TCastleTouchPosition
      read FPosition write SetPosition default tpManual;

    property Scale: Single read FScale write SetScale default 1;
  end;

{$endif read_interface}

{$ifdef read_implementation}

{ TCastleTouchControl ---------------------------------------------------------------- }

constructor TCastleTouchControl.Create(AOwner: TComponent);
begin
  inherited;
  FDragging := -1;
  FScale := 1;
end;

procedure TCastleTouchControl.SetScale(const Value: Single);
begin
  if FScale <> Value then
  begin
    FScale := Value;
    VisibleChange([chRectangle]);
  end;
end;

function TCastleTouchControl.TotalScale: Single;
begin
  if ContainerSizeKnown then
    Result := Scale * Container.Dpi / 96 else
    Result := 1;
end;

function TCastleTouchControl.FloatRect: TFloatRectangle;
begin
  // do not apply UIScale here to Width / Height,
  // it's already adjusted to physical size
  Result := FloatRectangle(FloatLeftBottomScaled,
    Round(Theme.Images[tiTouchCtlOuter].Width  * TotalScale),
    Round(Theme.Images[tiTouchCtlOuter].Height * TotalScale));
end;

procedure TCastleTouchControl.SetPosition(const Value: TCastleTouchPosition);
const
  CtlBorder = 24;
begin
  if FPosition <> Value then
  begin
    FPosition := Value;
    case Position of
      tpManual:
        begin
          Anchor(hpLeft, 0);
          Anchor(vpBottom, 0);
        end;
      tpLeft:
        begin
          Anchor(hpLeft, CtlBorder);
          Anchor(vpBottom, CtlBorder);
        end;
      tpRight:
        begin
          Anchor(hpRight, -CtlBorder);
          Anchor(vpBottom, CtlBorder);
        end;
    end;
    // VisibleChange([chRectangle]); // no need to call this, Anchor already called it
  end;
end;

function TCastleTouchControl.MaxOffsetDist: Integer;
begin
  Result := Round(TotalScale *
    (Theme.Images[tiTouchCtlOuter].Width -
     Theme.Images[tiTouchCtlInner].Width) / 2);
end;

procedure TCastleTouchControl.Render;
var
  LevOffsetTrimmedX, LevOffsetTrimmedY, MaxDist: Integer;
  LeverDist: Double;
  InnerRect: TRectangle;
  ImageInner, ImageOuter: TThemeImage;
  SR: TRectangle;
begin
  inherited;
  SR := ScreenRect;

  if FTouchMode = ctcmFlyUpdown then
  begin
    ImageInner := tiTouchCtlFlyInner;
    ImageOuter := tiTouchCtlFlyOuter;
  end else
  begin
    ImageInner := tiTouchCtlInner;
    ImageOuter := tiTouchCtlOuter;
  end;
  Theme.Draw(SR, ImageOuter, UIScale);

  // compute lever offset (must not move outside outer ring)
  LeverDist := FLeverOffset.Length;
  MaxDist := MaxOffsetDist;
  if LeverDist <= MaxDist then
  begin
    LevOffsetTrimmedX := Round(FLeverOffset[0]);
    LevOffsetTrimmedY := Round(FLeverOffset[1]);
  end else
  begin
    LevOffsetTrimmedX := Floor((FLeverOffset[0]*MaxDist)/LeverDist);
    LevOffsetTrimmedY := Floor((FLeverOffset[1]*MaxDist)/LeverDist);
  end;
  if FTouchMode = ctcmFlyUpdown then LevOffsetTrimmedX := 0;

  // draw lever
  InnerRect := Theme.Images[ImageInner].Rect; // rectangle at (0,0)
  InnerRect.Width  := Round(InnerRect.Width  * TotalScale);
  InnerRect.Height := Round(InnerRect.Height * TotalScale);
  InnerRect.Left   := SR.Left   + (SR.Width  - InnerRect.Width ) div 2 + LevOffsetTrimmedX;
  InnerRect.Bottom := SR.Bottom + (SR.Height - InnerRect.Height) div 2 + LevOffsetTrimmedY;

  Theme.Draw(InnerRect, ImageInner, UIScale);
end;

procedure TCastleTouchControl.SetTouchMode(const Value: TCastleTouchCtlMode);
begin
  if FTouchMode <> Value then
  begin
    FTouchMode := Value;
    { we may swap outer image depending on the TouchMode in some later version }
    VisibleChange([chRectangle]);
  end;
end;

function TCastleTouchControl.Press(const Event: TInputPressRelease): boolean;
begin
  Result := inherited;
  if Result or (Event.EventType <> itMouseButton) then Exit;

  Result := ExclusiveEvents;
  FDragging := Event.FingerIndex;
  FLeverOffset := TVector2.Zero;
end;

function TCastleTouchControl.Release(const Event: TInputPressRelease): boolean;
begin
  Result := inherited;
  if Result or (Event.EventType <> itMouseButton) then Exit;

  if FDragging = Event.FingerIndex then
  begin
    Result := ExclusiveEvents;

    FDragging := -1;
    FLeverOffset := TVector2.Zero;
    VisibleChange([chRender]); { repaint with lever back in the center }
  end;
end;

function TCastleTouchControl.Motion(const Event: TInputMotion): boolean;
begin
  Result := inherited;

  if (not Result) and (FDragging = Event.FingerIndex) then
  begin
    FLeverOffset := FLeverOffset + Event.Position - Event.OldPosition;
    VisibleChange([chRender]);
    Result := ExclusiveEvents;
  end;
end;

procedure TCastleTouchControl.GetSensorRotation(var X, Y, Z, Angle: Double);
var
  FxConst: Double;
begin
  FxConst := 10/MaxOffsetDist;
  if FTouchMode = ctcmHeadRotation then
  begin
    X :=  FLeverOffset[1] * FxConst;
    Y := -FLeverOffset[0] * FxConst;
    Angle := 1;
  end else
  if FTouchMode = ctcmWalkWithSideRot then
  begin
    Y := -FLeverOffset[0] * FxConst;
    Angle := 1;
  end;
end;

procedure TCastleTouchControl.GetSensorTranslation(var X, Y, Z, Length: Double);
var
  FxConst: Double;
begin
  FxConst := 200/MaxOffsetDist;
  case FTouchMode of
    ctcmWalking:
      begin
        X :=  FLeverOffset[0] * FxConst / 1.5;  { walking to the sides should be slower }
        Z := -FLeverOffset[1] * FxConst;
        Length := 20;
      end;
    ctcmWalkWithSideRot:
      begin
        Z := -FLeverOffset[1] * FxConst;
        Length := 20;
      end;
    ctcmFlyUpdown:
      begin
        Y := FLeverOffset[1] * FxConst;
        Length := 20;
      end;
    ctcmPanXY:
      begin
        X := -FLeverOffset[0] * FxConst;
        Y := -FLeverOffset[1] * FxConst;
        Length := 5;
      end;
  end;
end;

{$endif read_implementation}
