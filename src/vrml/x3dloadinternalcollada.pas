{
  Copyright 2008-2011 Michalis Kamburelis.

  This file is part of "Kambi VRML game engine".

  "Kambi VRML game engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Kambi VRML game engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{ Load Collada. }
unit X3DLoadInternalCollada;

{$I kambiconf.inc}

interface

uses VRMLNodes;

{ Load Collada file as X3D.

  Written based on Collada 1.3.1 and 1.4.1 specifications.
  Should handle any Collada 1.3.x or 1.4.x or 1.5.x version.
  http://www.gamasutra.com/view/feature/1580/introduction_to_collada.php?page=6
  suggests that "specification stayed quite stable between 1.1 and 1.3.1",
  which means that older versions (< 1.3.1) may be handled too.

  @param(AllowKambiExtensions If @true we may use some of our engine specific
    extensions. For example, Material.mirror may be <> 0,
    see [http://vrmlengine.sourceforge.net/kambi_vrml_extensions.php#section_ext_material_mirror].) }
function LoadCollada(const FileName: string;
  const AllowKambiExtensions: boolean = false): TX3DRootNode;

implementation

uses SysUtils, KambiUtils, KambiStringUtils, VectorMath,
  DOM, XMLRead, KambiXMLUtils, KambiWarnings, Classes, KambiClassUtils,
  FGL {$ifdef VER2_2}, FGLObjectList22 {$endif}, Math, X3DLoadInternalUtils;

{ Large missing stuff:

  - GPU shaders. We fully support the equivalent X3D nodes (for GLSL),
    so importing this from Collada (converting to X3D) is possible.

  - Animations. As an argument for supporting it, Blender *can* export
    some animations to Collada:

    - Transformation animation: Blender exports it,
      in a format that is close to Blender animation curves.
      There's a separate info about location.x, location.y etc. animation.
      Animation of rotation is animating angle of rotation around the X axis, etc.
      Animations are connected to Collada nodes by

        <channel source="#Cube_rotation_euler_Z-sampler" target="Cube/rotationZ.ANGLE"/>

      "target" attribute uses Collada id path.
      We'd have to group such animations of a vector components into a single
      animation (in X3D, you cannot animate translation.x separately,
      you only animate whole 3D translation vector).
      This is doable for our importer.

    - Shape keys animation from Blender is not exported to Collada, it seems.

    - Armature animation: Blender exports armature bones animation.
      Also, armature hierarchy is exported as Collada nodes.
      Armature bone names and weights are exported too.

      So armature is exported --- in a format reflecting armature setup in Blender,
      not as a processed effect it has on a model skin.
      Rendering it means performing bones+skin animation at runtime.
      X3D equivalent of this is H-Anim with skin, which we support fully.
      So importing such Collada is possible.

      It depends on importing first normal transformation animation
      (as the bones are animated just like normal transformations;
      there's no point in importing skin stuff if you can't import bones animation).

  These are all doable ideas, but also not trivial.
  Since Blender can export animations to Collada (and not yet to X3D),
  it would be quite useful.
  Contributions are welcome!
}

{ TCollada* helper containers ------------------------------------------------ }

type
  TColladaController = class
    Name: string;
    Source: string;
    BoundShapeMatrix: TMatrix4Single;
    BoundShapeMatrixIdentity: boolean;
  end;

  TColladaControllerList = class(specialize TFPGObjectList<TColladaController>)
  public
    { Find a TColladaController with given Name, @nil if not found. }
    function Find(const Name: string): TColladaController;
  end;

function TColladaControllerList.Find(const Name: string): TColladaController;
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    if Items[I].Name = Name then
      Exit(Items[I]);

  Result := nil;
end;

type
  TColladaEffect = class
    Appearance: TAppearanceNode;
    { If this effect contains a texture for diffuse, this is the name
      of texture coordinates in Collada.
      For now not used (we always take first input with TEXCOORD semantic
      to control the main texture, that affects the look (after lighting
      calculation, so not only diffuse). }
    DiffuseTexCoordName: string;
    destructor Destroy; override;
  end;

destructor TColladaEffect.Destroy;
begin
  FreeIfUnusedAndNil(Appearance);
  inherited;
end;

type
  TColladaEffectList = class(specialize TFPGObjectList<TColladaEffect>)
    { Find a TColladaEffect with given Name, @nil if not found. }
    function Find(const Name: string): TColladaEffect;
  end;

function TColladaEffectList.Find(const Name: string): TColladaEffect;
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    if Items[I].Appearance.NodeName = Name then
      Exit(Items[I]);
  Result := nil;
end;

type
  { Collada primitive (item handled by ReadPrimitiveCommon,
    from <poly*> or <tri*> or <lines*> elements within <mesh>),
    which are X3D geometries with a material name. }
  TColladaPrimitive = class
    { Collada material name (from "material" attribute of primitive element).
      For Collada 1.3.x, this is just a name of material in material library.
      For Collada 1.4.x, when instantiating geometry you specify which material
      name (inside geometry) corresponds to which material name on Materials
      list. }
    Material: string;
    X3DGeometry: TAbstractGeometryNode;
    destructor Destroy; override;
  end;

  TColladaPrimitiveList = specialize TFPGObjectList<TColladaPrimitive>;

destructor TColladaPrimitive.Destroy;
begin
  FreeIfUnusedAndNil(X3DGeometry);
  inherited;
end;

type
  TColladaGeometry = class
    { Collada geometry id. }
    Name: string;
    Primitives: TColladaPrimitiveList;
    constructor Create;
    destructor Destroy; override;
  end;

constructor TColladaGeometry.Create;
begin
  Primitives := TColladaPrimitiveList.Create;
end;

destructor TColladaGeometry.Destroy;
begin
  FreeAndNil(Primitives);
  inherited;
end;

type
  TColladaGeometryList = class (specialize TFPGObjectList<TColladaGeometry>)
  public
    { Find item with given Name, @nil if not found. }
    function Find(const Name: string): TColladaGeometry;
  end;

function TColladaGeometryList.Find(const Name: string): TColladaGeometry;
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    if Items[I].Name = Name then
      Exit(Items[I]);

  Result := nil;
end;

type
  TStringTextureNodeMap = class(specialize TFPGMap<string, TAbstractTextureNode>)
    { For given Key return it's data, or @nil if not found.
      In our usage, we never insert @nil node as data, so this is
      not ambiguous. }
    function Find(const Key: string): TAbstractTextureNode;
  end;

function TStringTextureNodeMap.Find(const Key: string): TAbstractTextureNode;
var
  Index: Integer;
begin
  { do not use "inherited Find", it expects list is sorted }
  Index := IndexOf(Key);
  if Index <> -1 then
    Result := Data[Index] else
    Result := nil;
end;

type
  { Collada materials. Data contains TColladaEffect, which is a reference
    to Effects list (it is not owned by this TColladaMaterialsMap). }
  TColladaMaterialsMap = class(specialize TFPGMap<string, TColladaEffect>)
    { For given Key return it's data, or @nil if not found.
      In our usage, we never insert @nil effect as data, so this is
      not ambiguous. }
    function Find(const Key: string): TColladaEffect;
  end;

function TColladaMaterialsMap.Find(const Key: string): TColladaEffect;
var
  Index: Integer;
begin
  { do not use "inherited Find", it expects list is sorted }
  Index := IndexOf(Key);
  if Index <> -1 then
    Result := Data[Index] else
    Result := nil;
end;

type
  { Collada <source>. This is a named container keeping a series of floats
    in Collada. It may contain only data for some specific purpose (like positions
    or normals or tex coords) or be interleaved with other data. }
  TColladaSource = class
    Name: string;
    Floats: TFloatList;
    Params: TKamStringList;
    { Collada <accessor> description of vectors inside Floats.
      Note that Count here refers to count of whole vectors (so it's usually
      < than Floats.Count). }
    Count, Stride, Offset: Integer;

    constructor Create;
    destructor Destroy; override;

    { Check components and counts before AssignToVectorXYZ.
      It @false, a warning is done, and some parameters are adjusted.
      You can then abort using this vector
      (if it can be reasonably ignored, e.g. for normals),
      or try AssignToVectorXYZ anyway
      (if it's necessary, e.g. when this is for vertex positions). }
    function CheckXYZ(out XIndex, YIndex, ZIndex: Integer): boolean;
    function CheckST(out SIndex, TIndex: Integer): boolean;

    { Extract from source an array of TVector3Single.
      Params will be checked to contain at least three vector components
      'X', 'Y', 'Z'. (These should be specified in <param name="..." type="float"/>).

      Order of X, Y, Z params (and thus order of components in our Floats)
      may be different, we will reorder them to XYZ anyway.
      This way Collada data may have XYZ or ST in a different order,
      and this method will reorder this suitable for X3D.

      Returns if components were fully correct (no warnings). }
    function AssignToVectorXYZ(const Value: TVector3SingleList): boolean;

    { Extract from source an array of TVector2Single, for texture coordinates.
      Like AssignToVectorXYZ, but for 2D vectors, with component names 'S' and 'T'
      (or 'U' and 'V'). }
    function AssignToVectorST(const Value: TVector2SingleList): boolean;
  end;

constructor TColladaSource.Create;
begin
  inherited;
  Params := TKamStringList.Create;
  Floats := TFloatList.Create;
end;

destructor TColladaSource.Destroy;
begin
  FreeAndNil(Params);
  FreeAndNil(Floats);
  inherited;
end;

function TColladaSource.CheckXYZ(out XIndex, YIndex, ZIndex: Integer): boolean;
var
  MinCount: Integer;
begin
  XIndex := Params.IndexOf('X');
  if XIndex = -1 then
  begin
    OnWarning(wtMajor, 'Collada', 'Missing "X" parameter (for 3D vector) in this <source>');
    Exit(false);
  end;

  YIndex := Params.IndexOf('Y');
  if YIndex = -1 then
  begin
    OnWarning(wtMajor, 'Collada', 'Missing "Y" parameter (for 3D vector) in this <source>');
    Exit(false);
  end;

  ZIndex := Params.IndexOf('Z');
  if ZIndex = -1 then
  begin
    OnWarning(wtMajor, 'Collada', 'Missing "Z" parameter (for 3D vector) in this <source>');
    Exit(false);
  end;

  MinCount := Offset + Stride * (Count - 1) + KambiUtils.Max(XIndex, YIndex, ZIndex) + 1;
  Result := Floats.Count >= MinCount;
  if not Result then
  begin
    OnWarning(wtMinor, 'Collada', Format('<accessor> count requires at least %d float values in <float_array>, but only %d are avilable',
      [MinCount, Floats.Count]));
    { force Count smaller, also force other params to common values }
    Stride := Max(Stride, 1);
    XIndex := 0;
    YIndex := 1;
    ZIndex := 2;
    Count := (Floats.Count - Offset) div Stride;
  end;
end;

function TColladaSource.AssignToVectorXYZ(const Value: TVector3SingleList): boolean;
var
  XIndex, YIndex, ZIndex, I: Integer;
begin
  Result := CheckXYZ(XIndex, YIndex, ZIndex);
  Value.Count := Count;
  for I := 0 to Count - 1 do
  begin
    Value.L[I][0] := Floats.L[Offset + Stride * I + XIndex];
    Value.L[I][1] := Floats.L[Offset + Stride * I + YIndex];
    Value.L[I][2] := Floats.L[Offset + Stride * I + ZIndex];
  end;
end;

function TColladaSource.CheckST(out SIndex, TIndex: Integer): boolean;
var
  MinCount: Integer;
begin
  SIndex := Params.IndexOf('S');
  if SIndex = -1 then
  begin
    SIndex := Params.IndexOf('U');
    if SIndex = -1 then
    begin
      OnWarning(wtMajor, 'Collada', 'Missing "S" or "U" parameter (1st component of 2D tex coord) in this <source>');
      Exit(false);
    end;
  end;

  TIndex := Params.IndexOf('T');
  if TIndex = -1 then
  begin
    TIndex := Params.IndexOf('V');
    if TIndex = -1 then
    begin
      OnWarning(wtMajor, 'Collada', 'Missing "T" or "V" parameter (2nd component of 2D tex coord) in this <source>');
      Exit(false);
    end;
  end;

  MinCount := Offset + Stride * (Count - 1) + Max(SIndex, TIndex) + 1;
  Result := Floats.Count >= MinCount;
  if not Result then
  begin
    OnWarning(wtMinor, 'Collada', Format('<accessor> count requires at least %d float values in <float_array>, but only %d are avilable',
      [MinCount, Floats.Count]));
    { force Count smaller, also force other params to common values }
    Stride := Max(Stride, 1);
    SIndex := 0;
    TIndex := 1;
    Count := (Floats.Count - Offset) div Stride;
  end;
end;

function TColladaSource.AssignToVectorST(const Value: TVector2SingleList): boolean;
var
  SIndex, TIndex, I: Integer;
begin
  Result := CheckST(SIndex, TIndex);
  Value.Count := Count;
  for I := 0 to Count - 1 do
  begin
    Value.L[I][0] := Floats.L[Offset + Stride * I + SIndex];
    Value.L[I][1] := Floats.L[Offset + Stride * I + TIndex];
  end;
end;

type
  TColladaSourceList = class(specialize TFPGObjectList<TColladaSource>)
  public
    { Find a TColladaSource with given Name, @nil if not found. }
    function Find(const Name: string): TColladaSource;
  end;

function TColladaSourceList.Find(const Name: string): TColladaSource;
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    if Items[I].Name = Name then
      Exit(Items[I]);
  Result := nil;
end;

type
  { Parse a sequence of integeres inside a string inside an XML element. }
  TIntegersParser = class
  private
    Content: string;
    FCurrent: Int64;
    SeekPos: Integer;
    Ended: boolean;
  public
    constructor Create(const PElement: TDOMElement);
    function GetNext: boolean;
    property Current: Int64 read FCurrent;
  end;

constructor TIntegersParser.Create(const PElement: TDOMElement);
begin
  inherited Create;
  Content := DOMGetTextData(PElement);
  SeekPos := 1;
end;

function TIntegersParser.GetNext: boolean;
var
  Token: string;
begin
  if Ended then Exit(false);

  Token := NextToken(Content, SeekPos);
  if Token = '' then
  begin
    Ended := true;
    Result := false;
  end else
  try
    FCurrent := StrToInt(Token);
    Result := true;
  except
    on E: EConvertError do
    begin
      OnWarning(wtMajor, 'Collada', 'Invalid integer: ' + E.Message);
      Ended := true; { don't read further }
      Result := false;
    end;
  end;
end;

type
  { Indexes of a single vertex. Used only together with TColladaIndexes,
    that knows which ones are relevant (Coord is always relevant,
    but TexCoord is relevant only if TexCoordIndexOffset <> -1,
    and Normal is relevant only if NormalIndexOffset <> -1). }
  TIndex = record Coord, TexCoord, Normal: Integer end;

  { Handling Collada <p> (indexes inside primitives) to fill X3D geometry indexes.
    Accepted geometry types are TIndexedFaceSetNode and TIndexedLineSetNode,
    as only such may be created for Collada primitives. }
  TColladaIndexes = class
  private
    Ints: TIntegersParser;
    FGeometry: TAbstractGeometryNode;
    FInputsCount, FCoordIndexOffset, FTexCoordIndexOffset, FNormalIndexOffset: Integer;
  public
    constructor Create(const Geometry: TAbstractGeometryNode;
      const InputsCount, CoordIndexOffset, TexCoordIndexOffset, NormalIndexOffset: Integer);
    destructor Destroy; override;
    procedure BeginElement(const PElement: TDOMElement);
    function ReadVertex(out Index: TIndex): boolean;
    function ReadAddVertex(out Index: TIndex): boolean;
    function ReadAddVertex: boolean;
    procedure AddVertex(const Index: TIndex);
    procedure PolygonEnd;
  end;

constructor TColladaIndexes.Create(
  const Geometry: TAbstractGeometryNode;
  const InputsCount, CoordIndexOffset, TexCoordIndexOffset, NormalIndexOffset: Integer);
begin
  inherited Create;
  FGeometry := Geometry;
  FInputsCount := InputsCount;
  FCoordIndexOffset := CoordIndexOffset;
  FTexCoordIndexOffset := TexCoordIndexOffset;
  FNormalIndexOffset := NormalIndexOffset;
end;

procedure TColladaIndexes.BeginElement(const PElement: TDOMElement);
begin
  FreeAndNil(Ints);
  Ints := TIntegersParser.Create(PElement);
end;

destructor TColladaIndexes.Destroy;
begin
  FreeAndNil(Ints);
  inherited;
end;

const
  EmptyIndex: TIndex = (Coord: -1; TexCoord: -1; Normal: -1);

function TColladaIndexes.ReadVertex(out Index: TIndex): boolean;
var
  I: Integer;
begin
  Index := EmptyIndex;

  for I := 0 to FInputsCount - 1 do
  begin
    if not Ints.GetNext then
    begin
      if I <> 0 then
        OnWarning(wtMajor, 'Collada', 'Indexes in <p> suddenly end, in the middle of a vertex');
      Exit(false);
    end;

    if I = FCoordIndexOffset then
      Index.Coord := Ints.Current else
    if I = FTexCoordIndexOffset then
      Index.TexCoord := Ints.Current else
    if I = FNormalIndexOffset then
      Index.Normal := Ints.Current;
  end;

  Result := true;
end;

function TColladaIndexes.ReadAddVertex(out Index: TIndex): boolean;
begin
  Result := ReadVertex(Index);
  if Result then
    AddVertex(Index);
end;

function TColladaIndexes.ReadAddVertex: boolean;
var
  IgnoreIndex: TIndex;
begin
  Result := ReadAddVertex(IgnoreIndex);
end;

procedure TColladaIndexes.AddVertex(const Index: TIndex);
begin
  if FGeometry is TIndexedFaceSetNode then
  begin
    TIndexedFaceSetNode(FGeometry).FdCoordIndex.Items.Add(Index.Coord);
    if FTexCoordIndexOffset <> -1 then
      TIndexedFaceSetNode(FGeometry).FdTexCoordIndex.Items.Add(Index.TexCoord);
    if FNormalIndexOffset <> -1 then
      TIndexedFaceSetNode(FGeometry).FdNormalIndex.Items.Add(Index.Normal);
  end else
  begin
    Assert(FGeometry is TIndexedLineSetNode);
    TIndexedLineSetNode(FGeometry).FdCoordIndex.Items.Add(Index.Coord);
  end;
end;

procedure TColladaIndexes.PolygonEnd;
begin
  AddVertex(EmptyIndex);
end;

{ LoadCollada ---------------------------------------------------------------- }

function LoadCollada(const FileName: string;
  const AllowKambiExtensions: boolean): TX3DRootNode;
var
  WWWBasePath: string;

  { List of Collada effects. Each contains an X3D Appearance node,
    with a name equal to Collada effect name. }
  Effects: TColladaEffectList;

  { List of Collada materials. Collada material is just a reference
    to Collada effect with a name.
    This way we handle instance_effect in <material> node.
    Many materials may refer to a single effect. }
  Materials: TColladaMaterialsMap;

  { List of Collada geometries. }
  Geometries: TColladaGeometryList;

  { List of Collada visual scenes, for <visual_scene> Collada elements.
    Every visual scene is X3D TAbstractX3DGroupingNode instance.
    This is for Collada >= 1.4.x (for Collada < 1.4.x,
    the <scene> element is directly placed as a rendered scene). }
  VisualScenes: TX3DNodeList;

  { List of Collada controllers. Read from library_controllers, used by
    instance_controller. }
  Controllers: TColladaControllerList;

  { List of Collada images (TAbstractTextureNode). NodeName of every instance
    comes from Collada "id" of <image> element (these are referred to
    by <init_from> contents from <surface>). }
  Images: TX3DNodeList;

  Cameras: TX3DNodeList;
  Lights: TX3DNodeList;

  ResultModel: TGroupNode absolute Result;

  Version14: boolean; //< Collada version >= 1.4.x

  { Read elements of type "common_color_or_texture_type" in Collada >= 1.4.x.
    If we have <color>, return this color (texture and coord names are then set to empty).
    If we have <texture>, return white color (and the appropriate texture
    and coord names; if texture name was empty, you want to treat it like not
    existing anyway). }
  function ReadColorOrTexture(Element: TDOMElement; out TextureName, TexCoordName: string): TVector3Single;
  var
    Child: TDOMElement;
  begin
    TextureName := '';
    TexCoordName := '';
    Result := White3Single;
    Child := DOMGetChildElement(Element, 'color', false);
    if Child <> nil then
    begin
      { I simply drop 4th color component, I don't know what's the use of this
        (alpha is exposed by effect/materials parameter transparency, so color
        alpha is supposed to mean something else ?). }
      Result := Vector3SingleCut(Vector4SingleFromStr(DOMGetTextData(Child)));
    end else
    begin
      Child := DOMGetChildElement(Element, 'texture', false);
      if Child <> nil then
      begin
        DOMGetAttribute(Child, 'texture', TextureName);
        DOMGetAttribute(Child, 'texcoord', TexCoordName);
      end;
    end;
  end;

  { Read elements of type "common_color_or_texture_type" in Collada >= 1.4.x,
    but allow only color specification. }
  function ReadColor(Element: TDOMElement): TVector3Single;
  var
    IgnoreTextureName, IgnoreTexCoordName: string;
  begin
    Result := ReadColorOrTexture(Element, IgnoreTextureName, IgnoreTexCoordName);
  end;

  { Read elements of type "common_float_or_param_type" in Collada >= 1.4.x. }
  function ReadFloatOrParam(Element: TDOMElement): Float;
  var
    FloatElement: TDOMElement;
  begin
    FloatElement := DOMGetChildElement(Element, 'float', false);
    if FloatElement <> nil then
    begin
      Result := StrToFloat(DOMGetTextData(FloatElement));
    end else
      { We don't support anything else than <float> here, just use
        default 1 eventually. }
      Result := 1.0;
  end;

  { Read the contents of the text data inside single child ChildTagName.
    Useful to handle things like <init_from> and <source> elements in Collada.
    Returns empty string if ChildTagName not present (or present present more
    than once) in Element. }
  function ReadChildText(Element: TDOMElement; const ChildTagName: string): string;
  var
    Child: TDOMElement;
  begin
    Child := DOMGetChildElement(Element, ChildTagName, false);
    if Child <> nil then
      Result := DOMGetTextData(Child) else
      Result := '';
  end;

  { Read the contents of the text data inside single child ChildTagName,
    interpret them as Float.

    Returns false when such child not found (or occurs more than once),
    or when text cannot be converted to float.
    In this case, Value is guaranteed not to be modified. }
  function ReadChildFloat(Element: TDOMElement; const ChildTagName: string;
    var Value: Float): boolean;
  var
    Child: TDOMElement;
  begin
    Child := DOMGetChildElement(Element, ChildTagName, false);
    Result := Child <> nil;
    if Result then
    try
      Value := StrToFloat(DOMGetTextData(Child));
    except on EConvertError do Result := false; end;
  end;

  function ReadChildFloat(Element: TDOMElement; const ChildTagName: string;
    var Value: Single): boolean;
  var
    ValueFloat: Float;
  begin
    ValueFloat := 0; { avoid uninitialized warnings }
    Result := ReadChildFloat(Element, ChildTagName, ValueFloat);
    if Result then
      Value := ValueFloat;
  end;

  { Read the contents of the text data inside single child ChildTagName,
    interpret them as TVector3Single.

    Returns false when such child not found (or occurs more than once),
    or when cannot be converted to float.
    In this case, Value is guaranteed not to be modified. }
  function ReadChildVector(Element: TDOMElement; const ChildTagName: string;
    var Value: TVector3Single): boolean;
  var
    Child: TDOMElement;
  begin
    Child := DOMGetChildElement(Element, ChildTagName, false);
    Result := Child <> nil;
    if Result then
    try
      Value := Vector3SingleFromStr(DOMGetTextData(Child));
    except on EConvertError do Result := false; end;
  end;

  { Read <effect>. Only for Collada >= 1.4.x.
    Adds effect to the Effects list. }
  procedure ReadEffect(EffectElement: TDOMElement);
  var
    { Effect instance and nodes, available to local procedures inside ReadEffect. }
    Effect: TColladaEffect;
    Appearance: TAppearanceNode;
    Mat: TMaterialNode;

    { Map of <surface> names to images (references from Images list) }
    Surfaces: TStringTextureNodeMap;
    { Map of <sampler2D> names to images (references from Images list) }
    Samplers2D: TStringTextureNodeMap;

    procedure ReadTechnique(TechniqueElement: TDOMElement);
    var
      Image: TAbstractTextureNode;
      TechniqueChild: TDOMElement;
      I: TXMLElementIterator;
      DiffuseTextureName, DiffuseTexCoordName: string;
      Transparency: Single;
      HasTransparency: boolean;
    begin
      { We actually treat <phong> and <blinn> and even <lambert> elements the same.
        X3D lighting equations specify that always Blinn
        (half-vector) technique is used. What's much more practically
        important, OpenGL uses Blinn method. So actually I always do
        blinn method (at least for real-time rendering). }
      TechniqueChild := DOMGetChildElement(TechniqueElement, 'phong', false);
      if TechniqueChild = nil then
        TechniqueChild := DOMGetChildElement(TechniqueElement, 'blinn', false);
      if TechniqueChild = nil then
        TechniqueChild := DOMGetChildElement(TechniqueElement, 'lambert', false);

      if TechniqueChild <> nil then
      begin
        { <transparent> (color) and <transparency> (float) should
          be multiplied with each other. So says the Collada spec
          ("Determining Transparency (Opacity)" in Chapter 7,
          and forum https://collada.org/public_forum/viewtopic.php?t=386).
          When only one is specified, the other is like 1.
          However, when neither one is specified, we obviously want to leave
          the model opaque (transparency = 0) so we need boolean HasTransparency. }
        Transparency := 1;
        HasTransparency := false;

        I := TXMLElementIterator.Create(TechniqueChild);
        try
          while I.GetNext do
          begin
            if I.Current.TagName = 'emission' then
              Mat.FdEmissiveColor.Value :=  ReadColor(I.Current) else
            if I.Current.TagName = 'ambient' then
              Mat.FdAmbientIntensity.Value := VectorAverage(ReadColor(I.Current)) else
            if I.Current.TagName = 'diffuse' then
            begin
              Mat.FdDiffuseColor.Value := ReadColorOrTexture(I.Current,
                DiffuseTextureName, DiffuseTexCoordName);
              if DiffuseTextureName <> '' then
              begin
                Image := Samplers2D.Find(DiffuseTextureName);
                if Image <> nil then
                begin
                  Effect.DiffuseTexCoordName := DiffuseTexCoordName;
                  Appearance.FdTexture.Value := Image;
                end else
                begin
                  Image := Images.FindName(DiffuseTextureName) as TAbstractTextureNode;
                  if Image <> nil then
                  begin
                    Effect.DiffuseTexCoordName := DiffuseTexCoordName;
                    Appearance.FdTexture.Value := Image;
                    { Happens e.g. on "Private Section/Faerie_Forrest_DAY/Faerie_Forrest_DAY.dae"
                      from collada.org/owl models. }
                    OnWarning(wtMajor, 'Collada', Format('<diffuse> texture refers to missing sampler2D name "%s". Found <image> with the same id, will use it',
                      [DiffuseTextureName]));
                  end else
                    OnWarning(wtMajor, 'Collada', Format('<diffuse> texture refers to missing sampler2D name "%s"',
                      [DiffuseTextureName]));
                end;
              end;
            end else
            if I.Current.TagName = 'specular' then
              Mat.FdSpecularColor.Value := ReadColor(I.Current) else
            if I.Current.TagName = 'shininess' then
              Mat.FdShininess.Value := ReadFloatOrParam(I.Current) / 128.0 else
            if I.Current.TagName = 'reflective' then
              {Mat.FdMirrorColor.Value := } ReadColor(I.Current) else
            if I.Current.TagName = 'reflectivity' then
            begin
              if AllowKambiExtensions then
                Mat.FdMirror.Value := ReadFloatOrParam(I.Current) else
                ReadFloatOrParam(I.Current);
            end else
            if I.Current.TagName = 'transparent' then
            begin
              Transparency *= VectorAverage(ReadColor(I.Current));
              HasTransparency := true;
            end else
            if I.Current.TagName = 'transparency' then
            begin
              Transparency *= ReadFloatOrParam(I.Current);
              HasTransparency := true;
            end else
            if I.Current.TagName = 'index_of_refraction' then
              {Mat.FdIndexOfRefraction.Value := } ReadFloatOrParam(I.Current);
          end;
        finally FreeAndNil(I) end;

        if HasTransparency then
          Mat.FdTransparency.Value := Transparency;
      end;
    end;

    { Read <newparam>. }
    procedure ReadNewParam(Element: TDOMElement);
    var
      Child: TDOMElement;
      Name, RefersTo: string;
      Image: TAbstractTextureNode;
    begin
      if DOMGetAttribute(Element, 'sid', Name) then
      begin
        Child := DOMGetChildElement(Element, 'surface', false);
        if Child <> nil then
        begin
          { Read <surface>. It has <init_from>, referring to name on Images. }
          RefersTo := ReadChildText(Child, 'init_from');
          Image := Images.FindName(RefersTo) as TAbstractTextureNode;
          if Image <> nil then
            Surfaces[Name] := Image else
            OnWarning(wtMajor, 'Collada', Format('<surface> refers to missing image name "%s"',
              [RefersTo]));
        end else
        begin
          Child := DOMGetChildElement(Element, 'sampler2D', false);
          if Child <> nil then
          begin
            { Read <sampler2D>. It has <source>, referring to name on Surfaces. }
            RefersTo := ReadChildText(Child, 'source');
            Image := Surfaces.Find(RefersTo);
            if Image <> nil then
              Samplers2D[Name] := Image else
              OnWarning(wtMajor, 'Collada', Format('<sampler2D> refers to missing surface name "%s"',
                [RefersTo]));
          end; { else not handled <newparam> }
        end;
      end;
    end;

  var
    Id: string;
    I: TXMLElementIterator;
    ProfileElement: TDOMElement;
  begin
    if not DOMGetAttribute(EffectElement, 'id', Id) then
      Id := '';

    Effect := TColladaEffect.Create;
    Effects.Add(Effect);

    Appearance := TAppearanceNode.Create(Id, WWWBasePath);
    Effect.Appearance := Appearance;

    Mat := TMaterialNode.Create('', WWWBasePath);
    Appearance.FdMaterial.Value := Mat;

    ProfileElement := DOMGetChildElement(EffectElement, 'profile_COMMON', false);
    if ProfileElement <> nil then
    begin
      Surfaces := TStringTextureNodeMap.Create;
      Samplers2D := TStringTextureNodeMap.Create;
      try
        I := TXMLElementIterator.Create(ProfileElement);
        try
          while I.GetNext do
            if I.Current.TagName = 'technique' then
              { Actually only one <technique> within <profile_COMMON> is allowed.
                But, since we loop anyway, it's not a problem to handle many. }
              ReadTechnique(I.Current) else
            if I.Current.TagName = 'newparam' then
              ReadNewParam(I.Current);
        finally FreeAndNil(I) end;
      finally
        FreeAndNil(Surfaces);
        FreeAndNil(Samplers2D);
      end;
    end;
  end;

  { Read <library_effects>. Only for Collada >= 1.4.x.
    All effects are added to the Effects list. }
  procedure ReadLibraryEffects(LibraryElement: TDOMElement);
  var
    I: TXMLElementFilteringIterator;
  begin
    I := TXMLElementFilteringIterator.Create(LibraryElement, 'effect');
    try
      while I.GetNext do
        ReadEffect(I.Current);
        { other I.Current.TagName not supported for now }
    finally FreeAndNil(I) end;
  end;

  { Read <material>. It is added to the Materials list. }
  procedure ReadMaterial(MatElement: TDOMElement);

    function ReadParamAsVector3(Element: TDOMElement): TVector3Single;
    var
      AType: string;
    begin
      if not DOMGetAttribute(Element, 'type', AType) then
      begin
        OnWarning(wtMinor, 'Collada', '<param> has no type attribute');
        Result := ZeroVector3Single;
      end else
      if AType <> 'float3' then
      begin
        OnWarning(wtMinor, 'Collada', 'Expected <param> with type "float3"');
        Result := ZeroVector3Single;
      end else
        Result := Vector3SingleFromStr(DOMGetTextData(Element));
    end;

    function ReadParamAsFloat(Element: TDOMElement): Float;
    var
      AType: string;
    begin
      if not DOMGetAttribute(Element, 'type', AType) then
      begin
        OnWarning(wtMinor, 'Collada', '<param> has no type attribute');
        Result := 0;
      end else
      if AType <> 'float' then
      begin
        OnWarning(wtMinor, 'Collada', 'Expected <param> with type "float"');
        Result := 0;
      end else
        Result := StrToFloat(DOMGetTextData(Element));
    end;

  var
    MatId: string;

    { For Collada < 1.4.x }
    procedure TryCollada13;
    var
      ShaderElement, TechniqueElement, PassElement, ProgramElement: TDOMElement;
      ParamName: string;
      I: TXMLElementFilteringIterator;
      Effect: TColladaEffect;
      Appearance: TAppearanceNode;
      Mat: TMaterialNode;
    begin
      Effect := TColladaEffect.Create;
      Effects.Add(Effect);

      Appearance := TAppearanceNode.Create(MatId, WWWBasePath);
      Effect.Appearance := Appearance;

      Mat := TMaterialNode.Create('', WWWBasePath);
      Appearance.FdMaterial.Value := Mat;

      { Collada 1.3 doesn't really have a concept of effects used by materials.
        But to be consistent, we add one effect (to Effects list)
        and one reference to it (to Materials list). }
      Materials[MatId] := Effect;

      ShaderElement := DOMGetChildElement(MatElement, 'shader', false);
      if ShaderElement <> nil then
      begin
         TechniqueElement := DOMGetChildElement(ShaderElement, 'technique', false);
         if TechniqueElement <> nil then
         begin
           PassElement := DOMGetChildElement(TechniqueElement, 'pass', false);
           if PassElement <> nil then
           begin
             ProgramElement := DOMGetChildElement(PassElement, 'program', false);
             if ProgramElement <> nil then
             begin
               I := TXMLElementFilteringIterator.Create(ProgramElement, 'param');
               try
                 while I.GetNext do
                   if DOMGetAttribute(I.Current, 'name', ParamName) then
                   begin
                     if ParamName = 'EMISSION' then
                       Mat.FdEmissiveColor.Value := ReadParamAsVector3(I.Current) else
                     if ParamName = 'AMBIENT' then
                       Mat.FdAmbientIntensity.Value := VectorAverage(ReadParamAsVector3(I.Current)) else
                     if ParamName = 'DIFFUSE' then
                       Mat.FdDiffuseColor.Value := ReadParamAsVector3(I.Current) else
                     if ParamName = 'SPECULAR' then
                       Mat.FdSpecularColor.Value := ReadParamAsVector3(I.Current) else
                     if ParamName = 'SHININESS' then
                       Mat.FdShininess.Value := ReadParamAsFloat(I.Current) / 128.0 else
                     if ParamName = 'REFLECTIVE' then
                       {Mat.FdMirrorColor.Value := } ReadParamAsVector3(I.Current) else
                     if ParamName = 'REFLECTIVITY' then
                     begin
                       if AllowKambiExtensions then
                         Mat.FdMirror.Value := ReadParamAsFloat(I.Current) else
                         ReadParamAsFloat(I.Current);
                     end else
                     (*
                     Blender Collada 1.3.1 exporter bug: it sets
                     type of TRANSPARENT param as "float".
                     Although content inicates "float3",
                     like Collada 1.3.1 spec requires (page 129),
                     and consistently with what is in Collada 1.4.1 spec.

                     I don't handle this anyway, so I just ignore it for now.
                     Should be reported to Blender.

                     if ParamName = 'TRANSPARENT' then
                       {Mat.FdTransparencyColor.Value := } ReadParamAsVector3(I.Current) else
                     *)
                     if ParamName = 'TRANSPARENCY' then
                       Mat.FdTransparency.Value := ReadParamAsFloat(I.Current);
                     { other ParamName not handled }
                   end;
               finally FreeAndNil(I) end;
             end;
           end;
         end;
      end;
    end;

    { For Collada >= 1.4.x }
    procedure TryCollada14;
    var
      InstanceEffect: TDOMElement;
      EffectId: string;
      Effect: TColladaEffect;
    begin
      if MatId = '' then Exit;

      InstanceEffect := DOMGetChildElement(MatElement, 'instance_effect', false);
      if InstanceEffect <> nil then
      begin
        if DOMGetAttribute(InstanceEffect, 'url', EffectId) and
           SCharIs(EffectId, 1, '#') then
        begin
          Delete(EffectId, 1, 1); { delete initial '#' char }
          Effect := Effects.Find(EffectId);
          if Effect <> nil then
            Materials[MatId] := Effect else
            OnWarning(wtMinor, 'Collada', Format('Material "%s" references ' +
              'non-existing effect "%s"', [MatId, EffectId]));
        end;
      end;
    end;

  begin
    if not DOMGetAttribute(MatElement, 'id', MatId) then
      MatId := '';

    if Version14 then
      TryCollada14 else
      TryCollada13;
  end;

  { Read <library_materials> (Collada >= 1.4.x) or
    <library type="MATERIAL"> (Collada < 1.4.x). }
  procedure ReadLibraryMaterials(LibraryElement: TDOMElement);
  var
    I: TXMLElementFilteringIterator;
  begin
    I := TXMLElementFilteringIterator.Create(LibraryElement, 'material');
    try
      while I.GetNext do
        ReadMaterial(I.Current);
        { other I.Current.TagName not supported for now }
    finally FreeAndNil(I) end;
  end;

  { Read <geometry>. It is added to the Geometries list. }
  procedure ReadGeometry(GeometryElement: TDOMElement);
  var
    { Collada Geometry constructed, available to all Read* primitives local procedures. }
    Geometry: TColladaGeometry;

    Sources: TColladaSourceList;

    { Read "double sided" geometry property.

      There is no standard for this it seems, only some special MAYA markers:
      <extra><technique profile="MAYA"><double_sided>1</double_sided></technique></extra>
      Blender Collada 1.4 exporter, as well as various models from collada.org/owl
      use this, so it seems like a standard in practice. }
    function ReadDoubleSided(GeometryE: TDOMElement): boolean;
    var
      Child: TDOMElement;
      Profile: string;
    begin
      Result := false;

      Child := DOMGetChildElement(GeometryE, 'extra', false);
      if Child = nil then Exit;

      Child := DOMGetChildElement(Child, 'technique', false);
      if Child = nil then Exit;

      if not (DOMGetAttribute(Child, 'profile', Profile) and
              (Profile = 'MAYA')) then
        Exit;

      Child := DOMGetChildElement(Child, 'double_sided', false);
      if Child = nil then Exit;

      Result := StrToIntDef(DOMGetTextData(Child), 0) <> 0;
    end;

    { Read <source> within <mesh>. }
    procedure ReadSource(SourceElement: TDOMElement);
    var
      FloatArray, Technique, Accessor: TDOMElement;
      SeekPos, FloatArrayCount, I: Integer;
      FloatArrayContents, Token, AccessorSource, ParamName, ParamType, FloatArrayId: string;
      Source: TColladaSource;
      It: TXMLElementFilteringIterator;
    begin
      Source := TColladaSource.Create;
      Sources.Add(Source);

      if not DOMGetAttribute(SourceElement, 'id', Source.Name) then
        Source.Name := '';

      FloatArray := DOMGetChildElement(SourceElement, 'float_array', false);
      if FloatArray <> nil then
      begin
        if not DOMGetIntegerAttribute(FloatArray, 'count', FloatArrayCount) then
        begin
          FloatArrayCount := 0;
          OnWarning(wtMinor, 'Collada', '<float_array> without a count attribute');
        end;

        if not DOMGetAttribute(FloatArray, 'id', FloatArrayId) then
          FloatArrayId := '';

        Source.Floats.Count := FloatArrayCount;
        FloatArrayContents := DOMGetTextData(FloatArray);

        SeekPos := 1;
        for I := 0 to FloatArrayCount - 1 do
        begin
          Token := NextToken(FloatArrayContents, SeekPos);
          if Token = '' then
          begin
            OnWarning(wtMinor, 'Collada', 'Actual number of tokens in <float_array>' +
              ' less than declated in the count attribute');
            Break;
          end;
          Source.Floats.L[I] := StrToFloat(Token);
        end;

        Technique := DOMGetChildElement(SourceElement, 'technique_common', false);
        if Technique = nil then
        begin
          Technique := DOMGetChildElement(SourceElement, 'technique', false);
          { TODO: actually, I should search for technique with profile="COMMON"
            in this case, right ? }
        end;

        if Technique <> nil then
        begin
          Accessor := DOMGetChildElement(Technique, 'accessor', false);

          { read <accessor> attributes }

          if not DOMGetIntegerAttribute(Accessor, 'count', Source.Count) then
          begin
            OnWarning(wtMinor, 'Collada', '<accessor> has no count attribute');
            Source.Count := 0;
          end;

          if not DOMGetIntegerAttribute(Accessor, 'stride', Source.Stride) then
            { default, according to Collada spec }
            Source.Stride := 1;

          if not DOMGetIntegerAttribute(Accessor, 'offset', Source.Offset) then
            { default, according to Collada spec }
            Source.Offset := 0;

          if not DOMGetAttribute(Accessor, 'source', AccessorSource) then
          begin
            OnWarning(wtMinor, 'Collada', '<accessor> has no source attribute');
            AccessorSource := '';
          end;

          { We read AccessorSource only to check here }
          if AccessorSource <> '#' + FloatArrayId then
            OnWarning(wtMajor, 'Collada', '<accessor> source does not refer to <float_array> in the same <source>, this is not supported');

          It := TXMLElementFilteringIterator.Create(Accessor, 'param');
          try
            while It.GetNext do
            begin
              if not DOMGetAttribute(It.Current, 'name', ParamName) then
              begin
                OnWarning(wtMajor, 'Collada', 'Missing "name" of <param>');
                { TODO: this should not be required? }
                Continue;
              end;

              if not DOMGetAttribute(It.Current, 'type', ParamType) then
              begin
                OnWarning(wtMajor, 'Collada', 'Missing "type" of <param>');
                Continue;
              end;

              if ParamType <> 'float' then
              begin
                OnWarning(wtMajor, 'Collada', Format('<param> type "%s" is not supported',
                  [ParamType]));
                Continue;
              end;

              Source.Params.Add(ParamName);
            end;
          finally FreeAndNil(It) end;
        end;
      end;
    end;

  var
    { We take care to share coordinates, tex coordinates and normal vectors,
      so that they are stored efficiently in memory and can be saved using
      X3D DEF/USE mechanism. Coordinates are always shared by all primitives
      within the geometry. Each primitive may potentially have different tex coords
      or normals arrays, or they may share the same. }

    { Collada coordinates.
      Based on <source> indicated by last <vertices> element. }
    Coord: TCoordinateNode;
    { Assigning to Coord using AssignToVectorXYZ went without trouble. }
    CoordCorrect: boolean;

    { Collada texture coords used by last primitive.
      Based on <source> indicated by <input semantic="TEXCOORD"> element within
      primitive. NodeName corresponds to <source> id. }
    LastTexCoord: TTextureCoordinateNode;

    { Collada normal used by last primitive.
      Based on <source> indicated by <input semantic="NORMAL"> element within
      primitive. NodeName corresponds to <source> id. }
    LastNormal: TNormalNode;

    { DoubleSided, should be used by ReadPrimitiveCommon to set X3D solid field. }
    DoubleSided: boolean;

    { Read <vertices> within <mesh> }
    procedure ReadVertices(VerticesElement: TDOMElement);
    var
      I: TXMLElementFilteringIterator;
      InputSemantic, InputSourceName, Id: string;
      InputSource: TColladaSource;
    begin
      if Coord <> nil then
      begin
        OnWarning(wtMajor, 'Collada', '<vertices> specified multiple times within a geometry');
        FreeIfUnusedAndNil(Coord);
      end;

      if not DOMGetAttribute(VerticesElement, 'id', Id) then
        Id := '';

      Coord := TCoordinateNode.Create(Id, WWWBasePath);
      CoordCorrect := true;

      I := TXMLElementFilteringIterator.Create(VerticesElement, 'input');
      try
        while I.GetNext do
          if DOMGetAttribute(I.Current, 'semantic', InputSemantic) and
             (InputSemantic = 'POSITION') and
             DOMGetAttribute(I.Current, 'source', InputSourceName) and
             SCharIs(InputSourceName, 1, '#') then
          begin
            Delete(InputSourceName, 1, 1); { delete leading '#' char }
            InputSource := Sources.Find(InputSourceName);
            if InputSource <> nil then
            begin
              CoordCorrect := InputSource.AssignToVectorXYZ(Coord.FdPoint.Items);
              Exit;
            end else
            begin
              OnWarning(wtMinor, 'Collada', Format('Source attribute ' +
                '(of <input> element within <vertices>) ' +
                'references non-existing source "%s"', [InputSourceName]));
            end;
          end;
      finally FreeAndNil(I) end;

      OnWarning(wtMinor, 'Collada', '<vertices> element has no <input> child' +
        ' with semantic="POSITION" and some source attribute');
    end;

    { Read common things of primitive (<poly*>, <tri*>, <lines*>) within <mesh>.
      - Creates X3D geometry node, initializes it's coordinates
        and other fiels (but leaves *Index fields empty).
      - Adds it to Geometry.Primitives.
      - Returns Indexes instance, to parse indexes of this primitive. }
    function ReadPrimitiveCommon(PrimitiveE: TDOMElement): TColladaIndexes;
    var
      I: TXMLElementFilteringIterator;
      InputSemantic, InputSourceId, X3DGeometryName: string;
      Primitive: TColladaPrimitive;
      InputSource: TColladaSource;
      IndexedFaceSet: TIndexedFaceSetNode;
      IndexedLineSet: TIndexedLineSetNode;
      InputsCount, CoordIndexOffset, TexCoordIndexOffset, NormalIndexOffset: Integer;
    begin
      CoordIndexOffset := 0;
      TexCoordIndexOffset := -1;
      NormalIndexOffset := -1;

      Primitive := TColladaPrimitive.Create;
      Geometry.Primitives.Add(Primitive);

      IndexedFaceSet := nil;
      IndexedLineSet := nil;

      X3DGeometryName := Format('%s_collada_primitive_%d',
        { There may be multiple primitives inside a single Collada <geometry> node,
          so use Geometry.Primitives.Count to name them uniquely for X3D. }
        [Geometry.Name, Geometry.Primitives.Count]);

      if (PrimitiveE.TagName = 'lines') or
         (PrimitiveE.TagName = 'linestrips') then
      begin
        IndexedLineSet := TIndexedLineSetNode.Create(X3DGeometryName, WWWBasePath);
        IndexedLineSet.FdCoord.Value := Coord;
        Primitive.X3DGeometry := IndexedLineSet;
      end else
      begin
        IndexedFaceSet := TIndexedFaceSetNode.Create(X3DGeometryName, WWWBasePath);
        IndexedFaceSet.FdSolid.Value := not DoubleSided;
        { For VRML >= 2.0, creaseAngle is 0 by default.
          TODO: what is the default normal generation for Collada? }
        IndexedFaceSet.FdCreaseAngle.Value := NiceCreaseAngle;
        IndexedFaceSet.FdCoord.Value := Coord;
        Primitive.X3DGeometry := IndexedFaceSet;
      end;

      if DOMGetAttribute(PrimitiveE, 'material', Primitive.Material) then
      begin
        { Collada 1.4.1 spec says that this is just material name.
          Collada 1.3.1 spec says that this is URL. }
        if (not Version14) and SCharIs(Primitive.Material, 1, '#') then
          Delete(Primitive.Material, 1, 1);
      end; { else leave Primitive.Material as '' }

      InputsCount := 0;

      I := TXMLElementFilteringIterator.Create(PrimitiveE, 'input');
      try
        while I.GetNext do
        begin
          { we must count all inputs, since parsing <p> elements depends
            on InputsCount }
          Inc(InputsCount);
          if DOMGetAttribute(I.Current, 'semantic', InputSemantic) then
          begin
            if InputSemantic = 'VERTEX' then
            begin
              if not (DOMGetAttribute(I.Current, 'source', InputSourceId) and
                      (Coord <> nil) and
                      (InputSourceId = '#' + Coord.NodeName))  then
                OnWarning(wtMinor, 'Collada', '<input> with semantic="VERTEX" (of primitive element within <mesh>) does not reference <vertices> element within the same <mesh>');

              { Collada requires offset in this case.
                For us, if there's no offset, just leave CoordIndexOffset default. }
              DOMGetIntegerAttribute(I.Current, 'offset', CoordIndexOffset);
            end else
            if InputSemantic = 'TEXCOORD' then
            begin
              DOMGetIntegerAttribute(I.Current, 'offset', TexCoordIndexOffset);

              { Only for IndexedFaceSet.
                In case of trouble with coordinates, don't use texCoord,
                they may be invalid (this is for invalid Blender 1.3 exporter) }
              if (IndexedFaceSet = nil) or (not CoordCorrect) then Continue;

              if DOMGetAttribute(I.Current, 'source', InputSourceId) then
              begin
                if SCharIs(InputSourceId, 1, '#') then
                  Delete(InputSourceId, 1, 1);
                if ((LastTexCoord <> nil) and
                    (LastTexCoord.NodeName = InputSourceId)) then
                  { we can reuse last X3D tex coord node }
                  IndexedFaceSet.FdTexCoord.Value := LastTexCoord else
                begin
                  InputSource := Sources.Find(InputSourceId);
                  if InputSource <> nil then
                  begin
                    { create and use new X3D tex coord node }
                    FreeIfUnusedAndNil(LastTexCoord);
                    LastTexCoord := TTextureCoordinateNode.Create(InputSourceId, WWWBasePath);
                    InputSource.AssignToVectorST(LastTexCoord.FdPoint.Items);
                    IndexedFaceSet.FdTexCoord.Value := LastTexCoord;
                  end else
                    OnWarning(wtMinor, 'Collada', Format('<source> with id "%s" for texture coordinates not found',
                      [InputSourceId]));
                end;
              end else
                OnWarning(wtMinor, 'Collada', 'Missing source for <input> with semantic="TEXCOORD". We have texture coord indexes, but they will be ignored, since we have no actual texture coords');
            end else
            if InputSemantic = 'NORMAL' then
            begin
              DOMGetIntegerAttribute(I.Current, 'offset', NormalIndexOffset);

              { Only for IndexedFaceSet.
                In case of trouble with coordinates, don't use normals,
                they may be invalid (this is for invalid Blender 1.3 exporter) }
              if (IndexedFaceSet = nil) or (not CoordCorrect) then Continue;

              if DOMGetAttribute(I.Current, 'source', InputSourceId) then
              begin
                if SCharIs(InputSourceId, 1, '#') then
                  Delete(InputSourceId, 1, 1);
                if ((LastNormal <> nil) and
                    (LastNormal.NodeName = InputSourceId)) then
                  { we can reuse last X3D normal node }
                  IndexedFaceSet.FdNormal.Value := LastNormal else
                begin
                  InputSource := Sources.Find(InputSourceId);
                  if InputSource <> nil then
                  begin
                    { create and use new X3D normal node }
                    FreeIfUnusedAndNil(LastNormal);
                    LastNormal := TNormalNode.Create(InputSourceId, WWWBasePath);
                    InputSource.AssignToVectorXYZ(LastNormal.FdVector.Items);
                    IndexedFaceSet.FdNormal.Value := LastNormal;
                  end else
                    OnWarning(wtMinor, 'Collada', Format('<source> with id "%s" for normals not found',
                      [InputSourceId]));
                end;
              end else
                OnWarning(wtMinor, 'Collada', 'Missing source for <input> with semantic="NORMAL". We have normal indexes, but they will be ignored, since we have no actual normals');
            end;
          end;
        end;
      finally FreeAndNil(I) end;

      Result := TColladaIndexes.Create(Primitive.X3DGeometry,
        InputsCount, CoordIndexOffset, TexCoordIndexOffset, NormalIndexOffset);
    end;

    { Read <polygons> within <mesh> }
    procedure ReadPolygons(PrimitiveE: TDOMElement);
    var
      I: TXMLElementFilteringIterator;
      Indexes: TColladaIndexes;
    begin
      Indexes := ReadPrimitiveCommon(PrimitiveE);
      try
        I := TXMLElementFilteringIterator.Create(PrimitiveE, 'p');
        try
          while I.GetNext do
          begin
            Indexes.BeginElement(I.Current);
            while Indexes.ReadAddVertex do ;
            Indexes.PolygonEnd;
          end;
        finally FreeAndNil(I) end;
      finally FreeAndNil(Indexes) end;
    end;

    { Read <polylist> within <mesh> }
    procedure ReadPolylist(PrimitiveE: TDOMElement);
    var
      VCountE, P: TDOMElement;
      I: Integer;
      Indexes: TColladaIndexes;
      VCount: TIntegersParser;
    begin
      Indexes := ReadPrimitiveCommon(PrimitiveE);
      try
        VCountE := DOMGetChildElement(PrimitiveE, 'vcount', false);
        P := DOMGetChildElement(PrimitiveE, 'p', false);

        if (VCountE <> nil) and (P <> nil) then
        begin
          Indexes.BeginElement(P);
          VCount := TIntegersParser.Create(VCountE);
          try
            { we will parse both VCount and Indexes now, at the same time }
            while VCount.GetNext do
            begin
              for I := 0 to VCount.Current - 1 do
                if not Indexes.ReadAddVertex then
                begin
                  OnWarning(wtMinor, 'Collada', 'Unexpected end of <p> data in <polylist>');
                  Exit;
                end;
              Indexes.PolygonEnd;
            end;
          finally FreeAndNil(VCount) end;
        end;
      finally FreeAndNil(Indexes) end;
    end;

    { Read <triangles> within <mesh> }
    procedure ReadTriangles(PrimitiveE: TDOMElement);
    var
      P: TDOMElement;
      Indexes: TColladaIndexes;
    begin
      Indexes := ReadPrimitiveCommon(PrimitiveE);
      try
        P := DOMGetChildElement(PrimitiveE, 'p', false);
        if P <> nil then
        begin
          Indexes.BeginElement(P);
          repeat
            if not Indexes.ReadAddVertex then Break;
            if not Indexes.ReadAddVertex then Break;
            if not Indexes.ReadAddVertex then Break;
            Indexes.PolygonEnd;
          until false;
        end;
      finally FreeAndNil(Indexes) end;
    end;

    { Read <trifans> within <mesh> }
    procedure ReadTriFans(PrimitiveE: TDOMElement);
    var
      I: TXMLElementFilteringIterator;
      Indexes: TColladaIndexes;
      Vertex1, Vertex2, VertexPrevious, VertexNext: TIndex;
    begin
      Indexes := ReadPrimitiveCommon(PrimitiveE);
      try
        I := TXMLElementFilteringIterator.Create(PrimitiveE, 'p');
        try
          while I.GetNext do
          begin
            Indexes.BeginElement(I.Current);
            if Indexes.ReadVertex(Vertex1) and
               Indexes.ReadVertex(Vertex2) and
               Indexes.ReadVertex(VertexPrevious) then
            begin
              Indexes.AddVertex(Vertex1);
              Indexes.AddVertex(Vertex2);
              Indexes.AddVertex(VertexPrevious);
              Indexes.PolygonEnd;
              while Indexes.ReadVertex(VertexNext) do
              begin
                Indexes.AddVertex(Vertex1);
                Indexes.AddVertex(VertexPrevious);
                Indexes.AddVertex(VertexNext);
                Indexes.PolygonEnd;
                VertexPrevious := VertexNext;
              end;
            end;
          end;
        finally FreeAndNil(I) end;
      finally FreeAndNil(Indexes) end;
    end;

    { Read <tristrips> within <mesh> }
    procedure ReadTriStrips(PrimitiveE: TDOMElement);
    var
      I: TXMLElementFilteringIterator;
      Indexes: TColladaIndexes;
      Vertex1, Vertex2, Vertex3, VertexNext: TIndex;
      Turn: boolean;
    begin
      Indexes := ReadPrimitiveCommon(PrimitiveE);
      try
        I := TXMLElementFilteringIterator.Create(PrimitiveE, 'p');
        try
          while I.GetNext do
          begin
            Turn := true;
            Indexes.BeginElement(I.Current);
            if Indexes.ReadVertex(Vertex1) and
               Indexes.ReadVertex(Vertex2) and
               Indexes.ReadVertex(Vertex3) then
            begin
              Indexes.AddVertex(Vertex1);
              Indexes.AddVertex(Vertex2);
              Indexes.AddVertex(Vertex3);
              Indexes.PolygonEnd;
              while Indexes.ReadVertex(VertexNext) do
              begin
                Indexes.AddVertex(Vertex3);
                Indexes.AddVertex(Vertex2);
                Indexes.AddVertex(VertexNext);
                Indexes.PolygonEnd;
                if Turn then
                  Vertex2 := VertexNext else
                  Vertex3 := VertexNext;
                Turn := not Turn;
              end;
            end;
          end;
        finally FreeAndNil(I) end;
      finally FreeAndNil(Indexes) end;
    end;

    { Read <lines> within <mesh> }
    procedure ReadLines(PrimitiveE: TDOMElement);
    var
      P: TDOMElement;
      Indexes: TColladaIndexes;
    begin
      Indexes := ReadPrimitiveCommon(PrimitiveE);
      try
        P := DOMGetChildElement(PrimitiveE, 'p', false);
        if P <> nil then
        begin
          Indexes.BeginElement(P);
          repeat
            if not Indexes.ReadAddVertex then Break;
            if not Indexes.ReadAddVertex then Break;
            Indexes.PolygonEnd;
          until false;
        end;
      finally FreeAndNil(Indexes) end;
    end;

    { TODO: <linestrips> should work fine, but untested }
    { Read <linestrips> within <mesh> }
    procedure ReadLineStrips(PrimitiveE: TDOMElement);
    var
      I: TXMLElementFilteringIterator;
      Indexes: TColladaIndexes;
    begin
      Indexes := ReadPrimitiveCommon(PrimitiveE);
      try
        I := TXMLElementFilteringIterator.Create(PrimitiveE, 'p');
        try
          while I.GetNext do
          begin
            Indexes.BeginElement(I.Current);
            while Indexes.ReadAddVertex do ;
            Indexes.PolygonEnd;
          end;
        finally FreeAndNil(I) end;
      finally FreeAndNil(Indexes) end;
    end;

  var
    Mesh: TDOMElement;
    I: TXMLElementIterator;
    GeometryId: string;
  begin
    if not DOMGetAttribute(GeometryElement, 'id', GeometryId) then
      GeometryId := '';

    DoubleSided := ReadDoubleSided(GeometryElement);

    Geometry := TColladaGeometry.Create;
    Geometry.Name := GeometryId;
    Geometries.Add(Geometry);

    Mesh := DOMGetChildElement(GeometryElement, 'mesh', false);
    if Mesh <> nil then
    begin
      Coord := nil;
      LastTexCoord := nil;
      LastNormal := nil;
      Sources := TColladaSourceList.Create;
      try
        I := TXMLElementIterator.Create(Mesh);
        try
          while I.GetNext do
            if I.Current.TagName = 'source' then
              ReadSource(I.Current) else
            if I.Current.TagName = 'vertices' then
              ReadVertices(I.Current) else
            if I.Current.TagName = 'polygons' then
              ReadPolygons(I.Current) else
            if I.Current.TagName = 'polylist' then
              ReadPolylist(I.Current) else
            if I.Current.TagName = 'triangles' then
              ReadTriangles(I.Current) else
            if I.Current.TagName = 'trifans' then
              ReadTriFans(I.Current) else
            if I.Current.TagName = 'tristrips' then
              ReadTriStrips(I.Current) else
            if I.Current.TagName = 'lines' then
              ReadLines(I.Current) else
            if I.Current.TagName = 'linestrips' then
              ReadLineStrips(I.Current) else
              OnWarning(wtMajor, 'Collada', Format('Element "%s" within <mesh> not supported',
                [I.Current.TagName]));
        finally FreeAndNil(I) end;
      finally
        FreeAndNil(Sources);
        FreeIfUnusedAndNil(Coord);
        { actually LastTexCoord is for sure used by something,
          we don't really have to finalize it here }
        FreeIfUnusedAndNil(LastTexCoord);
      end;
    end;
  end;

  { Read <library_geometries> (Collada >= 1.4.x) or
    <library type="GEOMETRY"> (Collada < 1.4.x). }
  procedure ReadLibraryGeometries(LibraryElement: TDOMElement);
  var
    I: TXMLElementFilteringIterator;
  begin
    I := TXMLElementFilteringIterator.Create(LibraryElement, 'geometry');
    try
      while I.GetNext do
        ReadGeometry(I.Current);
        { other I.Current.TagName not supported for now }
    finally FreeAndNil(I) end;
  end;

  { Read <library> element.
    Only for Collada < 1.4.x (Collada >= 1.4.x has  <library_xxx> elements). }
  procedure ReadLibrary(LibraryElement: TDOMElement);
  var
    LibraryType: string;
  begin
    if DOMGetAttribute(LibraryElement, 'type', LibraryType) then
    begin
      if LibraryType = 'MATERIAL' then
        ReadLibraryMaterials(LibraryElement) else
      if LibraryType = 'GEOMETRY' then
        ReadLibraryGeometries(LibraryElement);
        { other LibraryType not supported for now }
    end;
  end;

  { Read <matrix> or <bind_shape_matrix> element to given Matrix. }
  function ReadMatrix(MatrixElement: TDOMElement): TMatrix4Single; overload;
  var
    SeekPos: Integer;
    Row, Col: Integer;
    Token, Content: string;
  begin
    Content := DOMGetTextData(MatrixElement);

    SeekPos := 1;

    for Row := 0 to 3 do
      for Col := 0 to 3 do
      begin
        Token := NextToken(Content, SeekPos);
        if Token = '' then
        begin
          OnWarning(wtMinor, 'Collada', 'Matrix (<matrix> or <bind_shape_matrix> ' +
            'element) has not enough items');
          Break;
        end;
        Result[Col, Row] := StrToFloat(Token);
      end;
  end;

  { Read <lookat> element, return appropriate matrix. }
  function ReadLookAt(MatrixElement: TDOMElement): TMatrix4Single;
  var
    SeekPos: Integer;
    Content: string;

    function ReadVector(out Vector: TVector3Single): boolean;
    var
      Token: string;
      I: Integer;
    begin
      Result := true;

      for I := 0 to 2 do
      begin
        Token := NextToken(Content, SeekPos);
        if Token = '' then
        begin
          OnWarning(wtMinor, 'Collada', 'Unexpected end of data of <lookat>');
          Exit(false);
        end;
        Vector[I] := StrToFloat(Token);
      end;
    end;

  var
    Eye, Center, Up: TVector3Single;
  begin
    Content := DOMGetTextData(MatrixElement);

    SeekPos := 1;

    if ReadVector(Eye) and
       ReadVector(Center) and
       ReadVector(Up) then
      Result := LookAtMatrix(Eye, Center, Up);
  end;

  { Read <node> element, add it to ParentGroup. }
  procedure ReadNodeElement(ParentGroup: TAbstractX3DGroupingNode;
    NodeElement: TDOMElement);

    { For Collada material id, return the X3D Appearance (or @nil if not found). }
    function MaterialToX3D(MaterialId: string;
      InstantiatingElement: TDOMElement): TAppearanceNode;
    var
      BindMaterial, Technique: TDOMElement;
      InstanceMaterialSymbol, InstanceMaterialTarget: string;
      I: TXMLElementFilteringIterator;
      Effect: TColladaEffect;
    begin
      if MaterialId = '' then Exit(nil);

      { For InstantiatingElement = instance_geometry (Collada 1.4.x), this
        must be present.
        For InstantiatingElement = instance (Collada 1.3.x), this must not
        be present.
        (But we actually don't check these conditions, just handle any case.) }
      BindMaterial := DOMGetChildElement(InstantiatingElement, 'bind_material', false);
      if BindMaterial <> nil then
      begin
        Technique := DOMGetChildElement(BindMaterial, 'technique_common', false);
        if Technique <> nil then
        begin
          { read <instance_material list inside.
            This may contain multiple materials, but actually we're only
            interested in a single material, so we look for material with
            symbol = MaterialId. }
          I := TXMLElementFilteringIterator.Create(Technique, 'instance_material');
          try
            while I.GetNext do
              if DOMGetAttribute(I.Current, 'symbol', InstanceMaterialSymbol) and
                 (InstanceMaterialSymbol = MaterialId) and
                 DOMGetAttribute(I.Current, 'target', InstanceMaterialTarget) then
              begin
                { this should be true, target is URL }
                if SCharIs(InstanceMaterialTarget, 1, '#') then
                  Delete(InstanceMaterialTarget, 1, 1);

                { replace MaterialId with what is indicated by
                    <instance_material target="..."> }
                MaterialId := InstanceMaterialTarget;
              end;
          finally FreeAndNil(I) end;
        end;
      end;

      Effect := Materials.Find(MaterialId);
      if Effect = nil then
      begin
        OnWarning(wtMinor, 'Collada', Format('Referencing non-existing material name "%s"',
          [MaterialId]));
        Result := nil;
      end else
      begin
        Result := Effect.Appearance;
      end;
    end;

    { Add Collada geometry instance (many X3D Shape nodes) to given X3D Group. }
    procedure AddGeometryInstance(Group: TAbstractX3DGroupingNode;
      Geometry: TColladaGeometry; InstantiatingElement: TDOMElement);
    var
      Shape: TShapeNode;
      I: Integer;
      Primitive: TColladaPrimitive;
    begin
      for I := 0 to Geometry.Primitives.Count - 1 do
      begin
        Primitive := Geometry.Primitives[I];
        Shape := TShapeNode.Create('', WWWBasePath);
        Group.FdChildren.Add(Shape);
        Shape.FdGeometry.Value := Primitive.X3DGeometry;
        Shape.Appearance := MaterialToX3D(Primitive.Material, InstantiatingElement);
      end;
    end;

    { Read <instance_geometry>, adding resulting X3D nodes into
      ParentGroup. Actually, this is also for reading <instance> in Collada 1.3.1. }
    procedure ReadInstanceGeometry(ParentGroup: TAbstractX3DGroupingNode;
      InstantiatingElement: TDOMElement);
    var
      GeometryId: string;
      Geometry: TColladaGeometry;
    begin
      if DOMGetAttribute(InstantiatingElement, 'url', GeometryId) and
         SCharIs(GeometryId, 1, '#') then
      begin
        Delete(GeometryId, 1, 1);
        Geometry := Geometries.Find(GeometryId);
        if Geometry = nil then
          OnWarning(wtMinor, 'Collada', Format('<node> instantiates non-existing <geometry> element "%s"',
            [GeometryId])) else
          AddGeometryInstance(ParentGroup, Geometry, InstantiatingElement);
      end else
        OnWarning(wtMajor, 'Collada', Format('Element <%s> missing url attribute (that has to start with #)',
          [InstantiatingElement.TagName]));
    end;

    { Read <instance_*>, adding resulting X3D nodes into ParentGroup. }
    procedure ReadInstance(ParentGroup: TAbstractX3DGroupingNode;
      InstantiatingElement: TDOMElement; List: TX3DNodeList);
    var
      Id: string;
      Node: TX3DNode;
    begin
      if DOMGetAttribute(InstantiatingElement, 'url', Id) and
         SCharIs(Id, 1, '#') then
      begin
        Delete(Id, 1, 1);
        Node := List.FindName(Id);
        if Node = nil then
          OnWarning(wtMinor, 'Collada', Format('<node> instantiates non-existing element "%s"',
            [Id])) else
          ParentGroup.FdChildren.Add(Node);
      end else
        OnWarning(wtMajor, 'Collada', Format('Element <%s> missing url attribute (that has to start with #)',
          [InstantiatingElement.TagName]));
    end;

    { Read <instance_controller>, adding resulting X3D node into
      ParentGroup. }
    procedure ReadInstanceController(ParentGroup: TAbstractX3DGroupingNode;
      InstantiatingElement: TDOMElement);
    var
      ControllerId: string;
      Controller: TColladaController;
      Group: TAbstractX3DGroupingNode;
      Geometry: TColladaGeometry;
    begin
      if DOMGetAttribute(InstantiatingElement, 'url', ControllerId) and
         SCharIs(ControllerId, 1, '#') then
      begin
        Delete(ControllerId, 1, 1);
        Controller := Controllers.Find(ControllerId);
        if Controller = nil then
        begin
          OnWarning(wtMinor, 'Collada', Format('<node> instantiates non-existing ' +
            '<controller> element "%s"', [ControllerId]));
        end else
        begin
          Geometry := Geometries.Find(Controller.Source);
          if Geometry = nil then
          begin
            OnWarning(wtMinor, 'Collada', Format('<controller> references non-existing ' +
              '<geometry> element "%s"', [Controller.Source]));
          end else
          begin
            if Controller.BoundShapeMatrixIdentity then
            begin
              Group := TGroupNode.Create('', WWWBasePath);
            end else
            begin
              Group := TMatrixTransformNode.Create('', WWWBasePath);
              TMatrixTransformNode(Group).FdMatrix.Value := Controller.BoundShapeMatrix;
            end;
            ParentGroup.FdChildren.Add(Group);
            AddGeometryInstance(Group, Geometry, InstantiatingElement);
          end;
        end;
      end else
        OnWarning(wtMajor, 'Collada', Format('Element <%s> missing url attribute (that has to start with #)',
          [InstantiatingElement.TagName]));
    end;

  var
    { This is either TTransformNode or TMatrixTransformNode. }
    NodeTransform: TAbstractX3DGroupingNode;

    { Create new Transform node, place it as a child of current Transform node
      and switch current Transform node to the new one.

      The idea is that each
      Collada transformation creates new nested VRML Transform node
      (since Collada transformations may represent any transformation,
      not necessarily representable by a single VRML Transform node).

      Returns NodeTransform, typecasted to TTransformNode, for your comfort. }
    function NestedTransform: TTransformNode;
    var
      NewNodeTransform: TTransformNode;
    begin
      NewNodeTransform := TTransformNode.Create('', WWWBasePath);
      NodeTransform.FdChildren.Add(NewNodeTransform);

      NodeTransform := NewNodeTransform;
      Result := NewNodeTransform;
    end;

    function NestedMatrixTransform: TMatrixTransformNode;
    var
      NewNodeTransform: TMatrixTransformNode;
    begin
      NewNodeTransform := TMatrixTransformNode.Create('', WWWBasePath);
      NodeTransform.FdChildren.Add(NewNodeTransform);

      NodeTransform := NewNodeTransform;
      Result := NewNodeTransform;
    end;

  var
    I: TXMLElementIterator;
    NodeId: string;
    V3: TVector3Single;
    V4: TVector4Single;
  begin
    if not DOMGetAttribute(NodeElement, 'id', NodeId) then
      NodeId := '';

    NodeTransform := TTransformNode.Create(NodeId, WWWBasePath);
    ParentGroup.FdChildren.Add(NodeTransform);

    { First iterate to gather all transformations.

      For Collada 1.4, this shouldn't be needed (spec says that
      transforms must be before all instantiations).

      But Collada 1.3.1 specification doesn't say anything about the order.
      And e.g. Blender Collada 1.3 exporter in fact generates files
      with <instantiate> first, then <matrix>, and yes: it expects matrix
      should affect instantiated object. So the bottom line is that for
      Collada 1.3, I must first gather all transforms, then do instantiations. }

    I := TXMLElementIterator.Create(NodeElement);
    try
      while I.GetNext do
      begin
        if I.Current.TagName = 'matrix' then
        begin
          NestedMatrixTransform.FdMatrix.Value := ReadMatrix(I.Current);
        end else
        if I.Current.TagName = 'rotate' then
        begin
          V4 := Vector4SingleFromStr(DOMGetTextData(I.Current));
          if V4[3] <> 0.0 then
          begin
            NestedTransform.FdRotation.ValueDeg := V4;
          end;
        end else
        if I.Current.TagName = 'scale' then
        begin
          V3 := Vector3SingleFromStr(DOMGetTextData(I.Current));
          if not VectorsPerfectlyEqual(V3, Vector3Single(1, 1, 1)) then
          begin
            NestedTransform.FdScale.Value := V3;
          end;
        end else
        if I.Current.TagName = 'lookat' then
        begin
          NestedMatrixTransform.FdMatrix.Value := ReadLookAt(I.Current);
        end else
        if I.Current.TagName = 'skew' then
        begin
          { TODO }
        end else
        if I.Current.TagName = 'translate' then
        begin
          V3 := Vector3SingleFromStr(DOMGetTextData(I.Current));
          if not VectorsPerfectlyEqual(V3, ZeroVector3Single) then
          begin
            NestedTransform.FdTranslation.Value := V3;
          end;
        end;
      end;
    finally FreeAndNil(I); end;

    { Now iterate to read instantiations and recursive nodes. }

    I := TXMLElementIterator.Create(NodeElement);
    try
      while I.GetNext do
      begin
        if (I.Current.TagName = 'instance') or
           (I.Current.TagName = 'instance_geometry') then
          ReadInstanceGeometry(NodeTransform, I.Current) else
        if I.Current.TagName = 'instance_controller' then
          ReadInstanceController(NodeTransform, I.Current) else
        if I.Current.TagName = 'instance_camera' then
          ReadInstance(NodeTransform, I.Current, Cameras) else
        if I.Current.TagName = 'instance_light' then
          ReadInstance(NodeTransform, I.Current, Lights) else
        if I.Current.TagName = 'node' then
          ReadNodeElement(NodeTransform, I.Current);
      end;
    finally FreeAndNil(I) end;
  end;

  { Read <node> sequence within given SceneElement, adding nodes to Group.
    This is used to handle <visual_scene> for Collada 1.4.x
    and <scene> for Collada 1.3.x. }
  procedure ReadNodesSequence(Group: TAbstractX3DGroupingNode;
    SceneElement: TDOMElement);
  var
    I: TXMLElementFilteringIterator;
  begin
    I := TXMLElementFilteringIterator.Create(SceneElement, 'node');
    try
      while I.GetNext do
        ReadNodeElement(Group, I.Current);
    finally FreeAndNil(I) end;
  end;

  { Read <scene> element. }
  procedure ReadSceneElement(SceneElement: TDOMElement);
  var
    SceneId: string;

    procedure Collada14;
    var
      InstanceVisualScene: TDOMElement;
      VisualSceneId: string;
      VisualSceneIndex: Integer;
    begin
      InstanceVisualScene := DOMGetChildElement(SceneElement,
        'instance_visual_scene', false);
      if InstanceVisualScene <> nil then
      begin
        if DOMGetAttribute(InstanceVisualScene, 'url', VisualSceneId) and
           SCharIs(VisualSceneId, 1, '#') then
        begin
          Delete(VisualSceneId, 1, 1);
          VisualSceneIndex := VisualScenes.FindNodeName(VisualSceneId);
          if VisualSceneIndex = -1 then
          begin
            OnWarning(wtMinor, 'Collada', Format('<instance_visual_scene> instantiates non-existing ' +
              '<visual_scene> element "%s"', [VisualSceneId]));
          end else
          begin
            ResultModel.FdChildren.Add(VisualScenes[VisualSceneIndex]);
          end;
        end;
      end;
    end;

    procedure Collada13;
    var
      Group: TGroupNode;
    begin
      Group := TGroupNode.Create(SceneId, WWWBasePath);
      ResultModel.FdChildren.Add(Group);

      ReadNodesSequence(Group, SceneElement);
    end;

  begin
    if not DOMGetAttribute(SceneElement, 'id', SceneId) then
      SceneId := '';

    { <scene> element is different in two Collada versions, it's most clear
      to just branch and do different procedure depending on Collada version. }

    if Version14 then
      Collada14 else
      Collada13;
  end;

  { Read <visual_scene>. Obtained scene X3D node is added both
    to VisualScenes list and VisualScenesSwitch.choice. }
  procedure ReadVisualScene(VisualScenesSwitch: TSwitchNode;
    VisualSceneElement: TDOMElement);
  var
    VisualSceneId: string;
    Group: TGroupNode;
  begin
    if not DOMGetAttribute(VisualSceneElement, 'id', VisualSceneId) then
      VisualSceneId := '';

    Group := TGroupNode.Create(VisualSceneId, WWWBasePath);
    VisualScenes.Add(Group);
    VisualScenesSwitch.FdChildren.Add(Group);

    ReadNodesSequence(Group, VisualSceneElement);
  end;

  { Read <library_visual_scenes> from Collada 1.4.x }
  procedure ReadLibraryVisualScenes(LibraryElement: TDOMElement);
  var
    I: TXMLElementFilteringIterator;
    LibraryId: string;
    VisualScenesSwitch: TSwitchNode;
  begin
    if not DOMGetAttribute(LibraryElement, 'id', LibraryId) then
      LibraryId := '';

    { Library of visual scenes is simply a VRML Switch, with each
      scene inside as one choice. This way we export to VRML all
      scenes from Collada, even those not chosen as current scene.
      That's good --- it's always nice to keep some data when
      converting. }

    VisualScenesSwitch := TSwitchNode.Create(LibraryId, WWWBasePath);
    ResultModel.FdChildren.Add(VisualScenesSwitch);

    I := TXMLElementFilteringIterator.Create(LibraryElement, 'visual_scene');
    try
      while I.GetNext do
        ReadVisualScene(VisualScenesSwitch, I.Current);
        { other I.Current.TagName not supported for now }
    finally FreeAndNil(I) end;
  end;

  { Read <controller> from Collada 1.4.x }
  procedure ReadController(ControllerElement: TDOMElement);
  var
    Controller: TColladaController;
    Skin, BindShapeMatrix: TDOMElement;
  begin
    Controller := TColladaController.Create;
    Controllers.Add(Controller);
    Controller.BoundShapeMatrixIdentity := true;

    if not DOMGetAttribute(ControllerElement, 'id', Controller.Name) then
      Controller.Name := '';

    Skin := DOMGetChildElement(ControllerElement, 'skin', false);
    if Skin <> nil then
    begin
      if DOMGetAttribute(Skin, 'source', Controller.Source) then
      begin
        { this should be true, controller.source is URL }
        if SCharIs(Controller.Source, 1, '#') then
          Delete(Controller.Source, 1, 1);
      end;

      BindShapeMatrix := DOMGetChildElement(Skin, 'bind_shape_matrix', false);
      if BindShapeMatrix <> nil then
      begin
        Controller.BoundShapeMatrixIdentity := false;
        Controller.BoundShapeMatrix := ReadMatrix(BindShapeMatrix);
      end;
    end;
  end;

  { Read <library_images> (Collada 1.4.x). Fills Images list. }
  procedure ReadLibraryImages(LibraryElement: TDOMElement);
  var
    I: TXMLElementFilteringIterator;
    Image: TImageTextureNode;
    ImageId, ImageUrl: string;
  begin
    I := TXMLElementFilteringIterator.Create(LibraryElement, 'image');
    try
      while I.GetNext do
        if DOMGetAttribute(I.Current, 'id', ImageId) then
        begin
          Image := TImageTextureNode.Create(ImageId, WWWBasePath);
          Images.Add(Image);
          ImageUrl := ReadChildText(I.Current, 'init_from');
          if ImageUrl <> '' then
            Image.FdUrl.Items.Add(ImageUrl);
        end;
    finally FreeAndNil(I) end;
  end;

  { Read <library_controllers> from Collada 1.4.x }
  procedure ReadLibraryControllers(LibraryElement: TDOMElement);
  var
    I: TXMLElementFilteringIterator;
  begin
    I := TXMLElementFilteringIterator.Create(LibraryElement, 'controller');
    try
      while I.GetNext do
        ReadController(I.Current);
        { other I.Current.TagName not supported for now }
    finally FreeAndNil(I) end;
  end;

  { Read <library_cameras> (Collada 1.4.x). Fills Cameras list. }
  procedure ReadLibraryCameras(LibraryE: TDOMElement);
  var
    Id: string;
    CameraGroup: TGroupNode;

    procedure InitializeNavigationInfo(E: TDOMElement);
    var
      Navigation: TNavigationInfoNode;
      ZNear, ZFar: Float;
    begin
      Navigation := TNavigationInfoNode.Create(Id + '_navigation_info', WWWBasePath);
      CameraGroup.FdChildren.Add(Navigation);

      if ReadChildFloat(E, 'znear', ZNear) then
        Navigation.FdAvatarSize.Items[0] := ZNear * 2;

      if ReadChildFloat(E, 'zfar', ZFar) then
        Navigation.FdVisibilityLimit.Value := ZFar;
    end;

  var
    I: TXMLElementFilteringIterator;
    Viewpoint: TViewpointNode;
    OrthoViewpoint: TOrthoViewpointNode;
    OpticsE, TechniqueE, PerspectiveE, OrthographicE: TDOMElement;
    XFov, YFov, XMag, YMag, AspectRatio: Float;
  begin
    I := TXMLElementFilteringIterator.Create(LibraryE, 'camera');
    try
      while I.GetNext do
        if DOMGetAttribute(I.Current, 'id', Id) then
        begin
          CameraGroup := TGroupNode.Create(Id, WWWBasePath);
          Cameras.Add(CameraGroup);

          OpticsE := DOMGetChildElement(I.Current, 'optics', false);
          if OpticsE <> nil then
          begin
            TechniqueE := DOMGetChildElement(OpticsE, 'technique_common', false);
            if TechniqueE <> nil then
            begin
              PerspectiveE := DOMGetChildElement(TechniqueE, 'perspective', false);
              if PerspectiveE <> nil then
              begin
                Viewpoint := TViewpointNode.Create(Id + '_viewpoint', WWWBasePath);
                Viewpoint.FdPosition.Value := ZeroVector3Single;
                CameraGroup.FdChildren.Add(Viewpoint);

                { Try to get YFov, and use it as X3D fieldOfView.
                  It's not a perfect translation, the idea of fieldOfView
                  is just different (X3D doesn't force aspect ratio). }
                if ReadChildFloat(PerspectiveE, 'yfov', YFov) then
                  Viewpoint.FdFieldOfView.Value := DegToRad(YFov) else
                if ReadChildFloat(PerspectiveE, 'xfov', XFov) and
                   ReadChildFloat(PerspectiveE, 'aspect_ratio', AspectRatio) and
                   (AspectRatio > SingleEqualityEpsilon) then
                  { aspect_ratio = xfov / yfov, so we can calculate yfov }
                  Viewpoint.FdFieldOfView.Value := DegToRad(XFov) / AspectRatio;

                InitializeNavigationInfo(PerspectiveE);
              end else
              begin
                OrthographicE := DOMGetChildElement(TechniqueE, 'orthographic', false);
                if OrthographicE <> nil then
                begin
                  OrthoViewpoint := TOrthoViewpointNode.Create(Id + '_viewpoint', WWWBasePath);
                  OrthoViewpoint.FdPosition.Value := ZeroVector3Single;
                  CameraGroup.FdChildren.Add(OrthoViewpoint);

                  { Translation to X3D cannot be perfect, as fieldOfView
                    just works differently, and X3D automatically preserves
                    aspect ratio. We concentrate on setting vertical angle
                    right (as this one is usually smaller, and so determines
                    horizontal angle). }
                  if ReadChildFloat(OrthographicE, 'ymag', YMag) then
                  begin
                    OrthoViewpoint.FdFieldOfView.Items[1] := -YMag;
                    OrthoViewpoint.FdFieldOfView.Items[3] :=  YMag;
                  end else
                  if ReadChildFloat(OrthographicE, 'xmag', XMag) then
                  begin
                    if ReadChildFloat(OrthographicE, 'aspect_ratio', AspectRatio) and
                       (AspectRatio > SingleEqualityEpsilon) then
                    begin
                      { aspect_ratio = xmag / ymag, so we can calculate ymag }
                      YMag := XMag / AspectRatio;
                      OrthoViewpoint.FdFieldOfView.Items[1] := -YMag;
                      OrthoViewpoint.FdFieldOfView.Items[3] :=  YMag;
                    end else
                    begin
                      OrthoViewpoint.FdFieldOfView.Items[0] := -XMag;
                      OrthoViewpoint.FdFieldOfView.Items[2] :=  XMag;
                    end;
                  end;

                  InitializeNavigationInfo(OrthographicE);
                end else
                  OnWarning(wtMinor, 'Collada', 'No supported camera inside <technique_common>');
              end;
            end else
              OnWarning(wtMinor, 'Collada', 'No supported camera technique inside <optics>');
          end else
            OnWarning(wtMinor, 'Collada', 'No <optics> inside camera');
        end;
    finally FreeAndNil(I) end;
  end;

  { Read <library_lights> (Collada 1.4.x). Fills Lights list. }
  procedure ReadLibraryLights(LibraryE: TDOMElement);

    function ReadAttenuation(E: TDOMElement): TVector3Single;
    begin
      Result := Vector3Single(1, 0, 0);
      ReadChildFloat(E, 'constant_attenuation', Result[0]);
      ReadChildFloat(E, 'linear_attenuation', Result[1]);
      ReadChildFloat(E, 'quadratic_attenuation', Result[2]);
    end;

  var
    I: TXMLElementFilteringIterator;
    Light: TAbstractLightNode;
    Point: TPointLightNode;
    Directional: TDirectionalLightNode;
    Spot: TSpotLightNode;
    Id, Profile: string;
    TechniqueE, LightE, ExtraE: TDOMElement;
    FalloffAngle, Radius: Float;
    LightColor: TVector3Single;
  begin
    I := TXMLElementFilteringIterator.Create(LibraryE, 'light');
    try
      while I.GetNext do
        if DOMGetAttribute(I.Current, 'id', Id) then
        begin
          Light := nil;

          TechniqueE := DOMGetChildElement(I.Current, 'technique_common', false);
          if TechniqueE <> nil then
          begin
            LightE := DOMGetChildElement(TechniqueE, 'point', false);
            if LightE <> nil then
            begin
              Point := TPointLightNode.Create(Id, WWWBasePath);
              Point.FdAttenuation.Value := ReadAttenuation(LightE);
              Light := Point;
            end else
            begin
              LightE := DOMGetChildElement(TechniqueE, 'directional', false);
              if LightE <> nil then
              begin
                Directional := TDirectionalLightNode.Create(Id, WWWBasePath);
                { default X3D light direction is -Z, matches Collada }
                Light := Directional;
              end else
              begin
                LightE := DOMGetChildElement(TechniqueE, 'spot', false);
                if LightE <> nil then
                begin
                  Spot := TSpotLightNode.Create(Id, WWWBasePath);
                  Spot.FdAttenuation.Value := ReadAttenuation(LightE);
                  { default X3D spot direction is -Z, matches Collada }
                  if not ReadChildFloat(LightE, 'falloff_angle', FalloffAngle) then
                    FalloffAngle := 180; { Collada default }
                  Spot.FdCutOffAngle.Value := DegToRad(FalloffAngle);
                  { falloff_exponent cannot be nicely translated to X3D beamWidth,
                    see notes about SpotLight.beamWidth at VRML/X3D renderer. }
                  Light := Spot;
                end else
                begin
                  LightE := DOMGetChildElement(TechniqueE, 'ambient', false);
                  if LightE <> nil then
                  begin
                    Point := TPointLightNode.Create(Id, WWWBasePath);
                    { ambient light can be translated to normal PointLight with
                      intensity = 0 (this scales diffuse and specular to zero). }
                    Point.FdIntensity.Value := 0;
                    Point.FdAmbientIntensity.Value := 1;
                    Light := Point;
                  end else
                    OnWarning(wtMinor, 'Collada', 'No supported light inside <technique_common>');
                end;
              end;
            end;
          end else
            OnWarning(wtMinor, 'Collada', 'No supported technique inside <light>');

          if Light <> nil then
          begin
            Light.FdGlobal.Value := true;
            if ReadChildVector(LightE, 'color', LightColor) then
              Light.FdColor.Value := LightColor;
            if Light is TAbstractPositionalLightNode then
            begin
              { calculate light radius }
              Radius := MaxSingle;
              ExtraE := DOMGetChildElement(I.Current, 'extra', false);
              if ExtraE <> nil then
              begin
                TechniqueE := DOMGetChildElement(ExtraE, 'technique', false);
                if (TechniqueE <> nil) and
                   DOMGetAttribute(TechniqueE, 'profile', Profile) and
                   (Profile = 'blender') then
                  ReadChildFloat(TechniqueE, 'dist', Radius);
              end;
              TAbstractPositionalLightNode(Light).FdRadius.Value := Radius;
            end;
            Lights.Add(Light);
          end;
        end;
    finally FreeAndNil(I) end;
  end;

var
  Doc: TXMLDocument;
  Version: string;
  I: TXMLElementIterator;
  LibraryE: TDOMElement;
begin
  Effects := nil;
  Materials := nil;
  Geometries := nil;
  VisualScenes := nil;
  Controllers := nil;
  Images := nil;
  Cameras := nil;
  Lights := nil;
  Result := nil;

  try
    try
      { ReadXMLFile always sets TXMLDocument param (possibly to nil),
        even in case of exception. So place it inside try..finally. }
      ReadXMLFile(Doc, FileName);

      Check(Doc.DocumentElement.TagName = 'COLLADA',
        'Root node of Collada file must be <COLLADA>');

      if not DOMGetAttribute(Doc.DocumentElement, 'version', Version) then
      begin
        Version := '';
        Version14 := false;
        OnWarning(wtMinor, 'Collada', '<COLLADA> element misses "version" attribute');
      end else
      begin
        { TODO: uhm, terrible hack... I should move my lazy ass and tokenize
          Version properly. }
        Version14 := IsPrefix('1.4.', Version) or IsPrefix('1.5.', Version);
      end;

      if DOMGetAttribute(Doc.DocumentElement, 'base', WWWBasePath) then
      begin
        { COLLADA.base is exactly for the same purpose as WWWBasePath.
          Use it (making sure it's absolute path). }
        WWWBasePath := ExpandFileName(WWWBasePath);
      end else
        WWWBasePath := ExtractFilePath(ExpandFilename(FileName));

      Effects := TColladaEffectList.Create;
      Materials := TColladaMaterialsMap.Create;
      Geometries := TColladaGeometryList.Create;
      VisualScenes := TX3DNodeList.Create(false);
      Controllers := TColladaControllerList.Create;
      Images := TX3DNodeList.Create(false);
      Cameras := TX3DNodeList.Create(false);
      Lights := TX3DNodeList.Create(false);

      Result := TX3DRootNode.Create('', WWWBasePath);
      Result.HasForceVersion := true;
      Result.ForceVersion := X3DVersion;

      { Read library_images. These may be referred to inside effects. }
      LibraryE := DOMGetChildElement(Doc.DocumentElement, 'library_images', false);
      if LibraryE <> nil then
        ReadLibraryImages(LibraryE);

      { Read library_effects.
        Effects may be referenced by materials,
        and there's no guarantee that library_effects will occur before
        library_materials. Testcase: "COLLLADA 1.4.1 Basic Samples/Cube/cube.dae". }
      LibraryE := DOMGetChildElement(Doc.DocumentElement, 'library_effects', false);
      if LibraryE <> nil then
        ReadLibraryEffects(LibraryE);

      { Read libraries of things that may be referenced within library_visual_scenes.
        For some models, <library_visual_scenes> may be before them (test from
        collada.org/owl/ : "New Uploads/COLLADA 1.5.0 Kinematics/COLLADA 1.5.0 Kinematics/COLLADA/KR150/kr150.dae") }
      I := TXMLElementIterator.Create(Doc.DocumentElement);
      try
        while I.GetNext do
          if I.Current.TagName = 'library' then { only Collada < 1.4.x }
            ReadLibrary(I.Current) else
          if I.Current.TagName = 'library_materials' then { only Collada >= 1.4.x }
            ReadLibraryMaterials(I.Current) else
          if I.Current.TagName = 'library_geometries' then { only Collada >= 1.4.x }
            ReadLibraryGeometries(I.Current) else
          if I.Current.TagName = 'library_cameras' then { only Collada >= 1.4.x }
            ReadLibraryCameras(I.Current) else
          if I.Current.TagName = 'library_lights' then { only Collada >= 1.4.x }
            ReadLibraryLights(I.Current) else
          if I.Current.TagName = 'library_controllers' then { only Collada >= 1.4.x }
            ReadLibraryControllers(I.Current);
      finally FreeAndNil(I); end;

      I := TXMLElementIterator.Create(Doc.DocumentElement);
      try
        while I.GetNext do
          if I.Current.TagName = 'library_visual_scenes' then { only Collada >= 1.4.x }
            ReadLibraryVisualScenes(I.Current) else
          if I.Current.TagName = 'scene' then
            ReadSceneElement(I.Current);
      finally FreeAndNil(I); end;

      Result.Meta.PutPreserve('source', ExtractFileName(FileName));
      Result.Meta['source-collada-version'] := Version;
    finally
      FreeAndNil(Doc);

      { Free unused Images before freeing Effects.
        That's because image may be used inside an effect,
        and would be invalid reference after freeing effect. }
      VRMLNodeList_FreeUnusedAndNil(Images);

      FreeAndNil(Materials);

      { Note: if some effect will be used by some geometry, but the
        geometry will not be used, everything will be still Ok
        (no memory leak). First freeing over Effects will not free this
        effect (since it's used), but then freeing over Geometries will
        free the geometry together with effect (since effect usage will
        drop to zero).

        This means that also other complicated case, when one effect is
        used twice, once by unused geometry node, second time by used geometry
        node, is also Ok. }
      FreeAndNil(Effects);
      FreeAndNil(Geometries);

      VRMLNodeList_FreeUnusedAndNil(Lights);
      VRMLNodeList_FreeUnusedAndNil(Cameras);
      VRMLNodeList_FreeUnusedAndNil(VisualScenes);
      FreeAndNil(Controllers);
    end;
    { eventually free Result *after* freeing other lists, to make sure references
      on Images, Materials etc. are valid when their unused items are freed. }
  except FreeAndNil(Result); raise; end;
end;

end.
