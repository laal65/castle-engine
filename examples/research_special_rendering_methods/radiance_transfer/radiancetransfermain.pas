{
  Copyright 2008-2018 Michalis Kamburelis.

  This file is part of "Castle Game Engine".

  "Castle Game Engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Castle Game Engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{ Simple Precomputed Radiance Transfer implementation.
  Self-shadowing with diffuse lighting.

  Navigate with mouse or keyboard (like view3dscene in Examine mode).

  AWSD, QE move the light.
  R, Shift+R change light radius.
  L, Shift+L change light intensity scale.
}
unit RadianceTransferMain;

{$I castleconf.inc}

interface

implementation

uses SysUtils, Classes, Math,
  {$ifdef CASTLE_OBJFPC} CastleGL, {$else} GL, GLExt, {$endif}
  CastleVectors, X3DNodes, CastleWindow,
  CastleClassUtils, CastleUtils, CastleRenderingCamera,
  CastleGLUtils, CastleScene, CastleKeysMouse, CastleSceneManager,
  CastleFilesUtils, CastleLog, CastleSphericalHarmonics, CastleImages,
  CastleGLCubeMaps, CastleStringUtils, CastleParameters, CastleColors,
  CastleApplicationProperties, CastleControls, CastleTransform;

type
  TViewMode = (vmNormal, vmSimpleOcclusion, vmFull);

var
  Window: TCastleWindowCustom;
  Scene: TCastleScene;
  ViewMode: TViewMode = vmFull;
  LightRadius: Single;
  LightPos: TVector3;

const
  { This is currently not synched with actual SHBasisCount used to generate
    the Scene. We just always prepare LightSHBasisCount components,
    eventually some of them will not be used in DoRadianceTransfer.

    While this is not optimal, this also may allow to use different SHBasis
    for different shapes within the Scene in the future. }

  LightSHBasisCount = 25;

var
  { This is calculated at the beginning of each Draw.
    Can be used then by DoRadianceTransfer. }
  LightSHBasis: array [0..LightSHBasisCount - 1] of Single;

  { Intensity specific for this light.
    Right now, we have only one light here, but the point is that we could
    have any number of lights.
    Only in 0..1 (as it's used as color component). }
  LightIntensity: Single = 1.0;

  { All lights intensity (obtained by getting light maps) are scaled
    by this. Can be in any range. }
  LightIntensityScale: Single = 100.0;

procedure DrawLight(ForMap: boolean);
begin
  glPushMatrix;
    glTranslatev(LightPos);

    if not ForMap then
    begin
      glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
      glEnable(GL_BLEND);
      glColor4f(1, 1, 0, 0.1);
    end else
      glColor3f(LightIntensity, LightIntensity, LightIntensity);

    CastleGluSphere(LightRadius, 10, 10);

    if not ForMap then
      glDisable(GL_BLEND);
  glPopMatrix;
end;

type
  TMySceneManager = class(TCastleSceneManager)
    procedure Render; override;
    procedure Render3D(const Params: TRenderParams); override;
  end;

procedure TMySceneManager.Render;
begin
  if not Scene.BoundingBox.IsEmpty then
  begin
    { SHVectorGLCapture wil draw maps, get them,
      and calculate LightSHBasis describing the light contribution
      (this will be used then by Scene.Render, during DoRadianceTransfer). }

    SHVectorGLCapture(LightSHBasis, Scene.BoundingBox.Center,
      @DrawLight, 100, 100, LightIntensityScale);

    { no need to reset RenderContext.Viewport
      inheried TCastleSceneManager.Render calls
      ApplyProjection that will already do it. }
  end;

  inherited;
end;

procedure TMySceneManager.Render3D(const Params: TRenderParams);
begin
  inherited;
  DrawLight(false);
end;

var
  SceneManager: TMySceneManager;

type
  THelper = class
    function DoRadianceTransfer(Node: TAbstractGeometryNode;
      RadianceTransfer: PVector3;
      const RadianceTransferCount: Cardinal): TVector3;
  end;

function THelper.DoRadianceTransfer(Node: TAbstractGeometryNode;
  RadianceTransfer: PVector3;
  const RadianceTransferCount: Cardinal): TVector3;
var
  I: Integer;
begin
  Assert(RadianceTransferCount > 0);

  if ViewMode = vmSimpleOcclusion then
  begin
    Result := RadianceTransfer[0];
  end else
  begin
    Result := TVector3.Zero;
    for I := 0 to Min(RadianceTransferCount, LightSHBasisCount) - 1 do
    begin
      Result.Data[0] += RadianceTransfer[I].Data[0] * LightSHBasis[I];
      Result.Data[1] += RadianceTransfer[I].Data[1] * LightSHBasis[I];
      Result.Data[2] += RadianceTransfer[I].Data[2] * LightSHBasis[I];
    end;
  end;
end;

procedure UpdateViewMode;
begin
  if ViewMode = vmNormal then
    Scene.Attributes.OnRadianceTransfer := nil else
    Scene.Attributes.OnRadianceTransfer := @THelper(nil).DoRadianceTransfer;
end;

procedure MenuClick(Container: TUIContainer; Item: TMenuItem);
begin
  case Item.IntData of
    10: ViewMode := vmNormal;
    11: ViewMode := vmSimpleOcclusion;
    12: ViewMode := vmFull;
    20: with Scene.Attributes do Lighting := not Lighting;
    100: Window.SaveScreenDialog(FileNameAutoInc(SUnformattable(ApplicationName) + '_screen_%d.png'));
    200: Window.Close;
    else Exit;
  end;
  UpdateViewMode;
  Window.Invalidate;
end;

procedure Update(Container: TUIContainer);

  procedure ChangeLightPosition(Coord, Change: Integer);
  begin
    LightPos.Data[Coord] += Change * Window.Fps.SecondsPassed *
      { scale by Box3DAvgSize, to get similar move on all models }
      Scene.BoundingBox.AverageSize;
    Window.Invalidate;
  end;

  procedure ChangeLightRadius(Change: Float);
  begin
    LightRadius *= Power(Change, Window.Fps.SecondsPassed);
    Window.Invalidate;
  end;

  procedure ChangeLightIntensityScale(Change: Float);
  begin
    LightIntensityScale *= Power(Change, Window.Fps.SecondsPassed);
    Window.Invalidate;
  end;

begin
  if Window.Pressed[K_A] then ChangeLightPosition(0, -1);
  if Window.Pressed[K_D] then ChangeLightPosition(0,  1);
  if Window.Pressed[K_S] then ChangeLightPosition(2, -1);
  if Window.Pressed[K_W] then ChangeLightPosition(2,  1);
  if Window.Pressed[K_Q] then ChangeLightPosition(1, -1);
  if Window.Pressed[K_E] then ChangeLightPosition(1,  1);

  if Window.Pressed[K_R] then
  begin
    if mkShift in Window.Pressed.Modifiers then
      ChangeLightRadius(1/1.8) else
      ChangeLightRadius(1.8);
  end;

  if Window.Pressed[K_L] then
  begin
    if mkShift in Window.Pressed.Modifiers then
      ChangeLightIntensityScale(1/1.5) else
      ChangeLightIntensityScale(1.5);
  end;
end;

function CreateMainMenu: TMenu;
var
  M: TMenu;
  Radio: TMenuItemRadio;
  RadioGroup: TMenuItemRadioGroup;
begin
  Result := TMenu.Create('Main menu');
  M := TMenu.Create('_Program');

    Radio := TMenuItemRadio.Create('_Normal (no PRT)', 10, ViewMode = vmNormal, true);
    RadioGroup := Radio.Group;
    M.Append(Radio);

    Radio := TMenuItemRadio.Create('_Simple Occlusion', 11, ViewMode = vmSimpleOcclusion, true);
    Radio.Group := RadioGroup;
    M.Append(Radio);

    Radio := TMenuItemRadio.Create('_Full Radiance Transfer', 12, ViewMode = vmFull, true);
    Radio.Group := RadioGroup;
    M.Append(Radio);

    M.Append(TMenuSeparator.Create);
    M.Append(TMenuItemChecked.Create('Apply OpenGL _Lighting', 20, { Scene.Attributes.Lighting } true, true));
    M.Append(TMenuSeparator.Create);
    M.Append(TMenuItem.Create('_Save Screen ...', 100, K_F5));
    M.Append(TMenuSeparator.Create);
    M.Append(TMenuItem.Create('_Exit', 200));
    Result.Append(M);
end;

{ One-time initialization of resources. }
procedure ApplicationInitialize;
var
  URL: string = 'data/chinchilla_with_prt.wrl.gz';
begin
  Parameters.CheckHighAtMost(1);
  if Parameters.High = 1 then
    URL := Parameters[1];

  Scene := TCastleScene.Create(Application);
  Scene.Load(URL);

  if Scene.BoundingBox.IsEmpty then
  begin
    LightRadius := 1;
    LightPos := Vector3(2, 0, 0);
  end else
  begin
    LightRadius := Scene.BoundingBox.AverageSize;
    LightPos := Scene.BoundingBox.Center;
    LightPos.Data[0] +=
      Scene.BoundingBox.Data[1].Data[0] -
      Scene.BoundingBox.Data[0].Data[0] + LightRadius;
  end;

  Window.Controls.InsertFront(TCastleSimpleBackground.Create(Application));

  SceneManager := TMySceneManager.Create(Application);
  SceneManager.Items.Add(Scene);
  { we will clear context by our own TCastleSimpleBackground,
    to keep SHVectorGLCapture visible for debugging }
  SceneManager.Transparent := true;
  SceneManager.MainScene := Scene;

  { TODO: this demo uses specialized rendering
    that currently assumes some fixed-function things set up. }
  GLFeatures.EnableFixedFunction := true;

  Window.Controls.InsertFront(SceneManager);

  Window.OnUpdate := @Update;

  InitializeSHBasisMap;

  UpdateViewMode;
end;

initialization
  { Set ApplicationName early, as our log uses it.
    Optionally you could also set ApplicationProperties.Version here. }
  ApplicationProperties.ApplicationName := 'radiance_transfer';

  { Start logging. Do this as early as possible,
    to log information and eventual warnings during initialization. }
  InitializeLog;

  { Initialize Application.OnInitialize. }
  Application.OnInitialize := @ApplicationInitialize;

  { Create and assign Application.MainWindow. }
  Window := TCastleWindowCustom.Create(Application);
  Application.MainWindow := Window;
  Window.MainMenu := CreateMainMenu;
  Window.OnMenuClick := @MenuClick;
end.
