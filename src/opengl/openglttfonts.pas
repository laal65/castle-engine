{
  Copyright 2001-2011 Michalis Kamburelis.

  This file is part of "Kambi VRML game engine".

  "Kambi VRML game engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Kambi VRML game engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{ OpenGL outline 3D fonts (TGLOutlineFont). }

unit OpenGLTTFonts;

{$I kambiconf.inc}
{$I openglmac.inc}

interface

uses OpenGLFonts, GL, GLU, TTFontsTypes, SysUtils, KambiGLUtils, KambiStringUtils;

const
  SimpleAsciiCharacters = [#32 .. #126];

type
  { Outline 3D font for OpenGL.

    This allows you to create outline font (that implements
    TGLOutlineFont_Abstract interface) based on information
    expressed as TTFontsTypes.TTrueTypeFont type.

    You can use font2pascal program to convert fonts' files
    to Pascal units with TTrueTypeFont constant. See various
    TTF_Xxx units, e.g. @code(../fonts/ttf_bitstreamverasans_unit.pas).

    So the basic road to use some font in your OpenGL program as 3d text is:
    @orderedList(
      @itemSpacing Compact
      @item(convert font to Pascal unit using font2pascal,
        to get unit like ttf_xxxunit.pas)
      @item(add to your uses clause TTF_Xxx_Unit and this unit, OpenGLTTFonts)
      @item(and now you can create object like
        @longCode# Font := TGLOutlineFont.Create(@@TTF_Xxx) #
       and use it like
        @longCode# Font.Print('foo'); #
      )
    ) }
  TGLOutlineFont = class(TGLOutlineFont_Abstract)
  private
    base : TGLuint;
    TTFont : PTrueTypeFont;

    TexturedXShift: TGLfloat;
    procedure TexturedBegin(const TexOriginX, TexOriginY: TGLfloat);
    procedure TexturedLetterEnd(const TexOriginX, TexOriginY: TGLfloat; const C: char);
    procedure TexturedEnd;

    procedure CharPrint(c: char);
    procedure CharPrintAndMove(c: char);

    procedure CharExtrusionPrint(const C: char; const Depth: Single;
      onlyLines: boolean = false);
    procedure CharExtrusionPrintAndMove(const C: char; const Depth: Single);
  public
    { Create instance from TrueTypeFont.

      @param(TrueTypeFont
        This is the pointer to your font, TTrueTypeFont.

        Note that to conserve the use of time and memory this constructor
        @italic(copies only this pointer (not the memory pointed to))
        so you must make sure that this pointer is valid for the lifetime
        of this object. Also you shouldn't modify the pointed font data
        after creating this instace (otherwise some things (like
        precalculated OpenGL display lists and stored font sizes)
        could get desynchronized).

        The usual simple way to keep all the assumptions above is to
        make TrueTypeFont a pointer to a constant defined in unit
        generated by font2pascal program.)

      @param(Depth
        This is the thickness of the font shape.
        When Depth > 0 then the resulting letters will be true 3D objects.
        Otherwise, when Depth = 0, the resulting letters will be flat.
        Note that Depth > 0 (i.e. 3D objects) increases triangle count
        of resulting letters, so the font with Depth > 0 will be rendered
        slower than the same font with Depth = 0.

        When Depth > 0, we automatically generate proper normals pointing
        out from CCW (for both front and back caps and side).
        For Depth < 0 results are undefined, don't use !

        When Depth = 0, no normals are generated.
        It's guaranteed that normal (0, 0, -1) points from CCW side, so you
        can call glNormal yourself if you want (and adjust it for your
        current glFrontFace setting).
      )

      @param(OnlyLines
        If @true then the font will be only a "skeleton" (only lines,
        no polygons).)

      @param(CharactersSubset If non-empty, this set defines the characters
        that will be actually rendered.

        Other characters can still be passed
        in strings to @link(Print) and other methods, they just will
        not be visible. (Although even invisible characters will still shift
        the "cursor" used when writing the string. This means that
        e.g. monospace font will be shifted appropriately, even if some
        characters were excluded by CharactersSubset.)

        By default we use SimpleAsciiCharacters constant here.

        This makes font preparations faster (for example,
        Debian Linux x86_64 currently has much slower GLU tesselator,
        and so optimizing by providing only SimpleAsciiCharacters makes sense).
        Also, font takes less memory space.)
    }
    constructor Create(TrueTypeFont: PTrueTypeFont;
      const depth: TGLfloat = 0.0;
      const onlyLines: boolean = false;
      const CharactersSubset: TSetOfChars = SimpleAsciiCharacters); overload;
    destructor Destroy; override;

    procedure Print(const s: string); override;
    procedure PrintAndMove(const s: string); override;
    function TextWidth(const s: string): single; override;
    function TextHeight(const s: string): single; override;

    { This renders the text additionally generating texture coordinates.

      texOriginX and texOriginY will map to texture coord = (0, 0),
      then texture coord will increase by 1 when the distance will
      increase by RowHeight.

      This requires one place on attrib stack of OpenGL.
      Version without the "AndMove" requires also one place
      on matrix modelview stack of OpenGL.

      @groupBegin }
    procedure PrintTexturedAndMove(const s: string;
      const texOriginX, texOriginY: TGLfloat);

    procedure PrintTextured(const s: string;
      const texOriginX, texOriginY: TGLfloat);
    { @groupEnd }

    { Render extrusion of given text. This renders the side walls of text
      that would be created when pushing the text into z = Depth.

      If you want to render letters as solid 3D objects, then the text
      has three parts: front cap (you get this by normal Print or PrintAndMove
      or PrintTexturedAndMove), back cap (this is the same thing as front cap
      but with z = Depth) and extrusion (connecting front cap and back cap;
      this is rendered using this method).

      This is supposed to be used on text created with Depth = 0 at
      constructor. Text created with Depth <> 0 at constructions already
      gets this extrusion (along with back cap) rendered by normal
      Print or PrintAndMove etc. methods.

      This generates proper normal vectors. For now, they are only suitable
      for flat shading, so be sure to render fonts with flat shading if using
      this. Generated normals point out from CCW side,
      when Depth > 0 (when Depth < 0, things are reversed, so normals are from CW).

      PrintTexturedExtrusionAndMove version generates also proper
      texture coordinates (matching coordinates made by PrintTexturedAndMove).

      This doesn't use any display list.

      @groupBegin }
    procedure PrintExtrusionAndMove(const S: string; const Depth: Single);

    procedure PrintTexturedExtrusionAndMove(
      const S: string; const Depth: Single;
      const TexOriginX, TexOriginY: TGLfloat);
    { @groupEnd }
  end;

implementation

uses KambiUtils, VectorMath, GLVersionUnit;

const
  {w tej chwili zawsze 256 ale byc moze kiedys cos tu zmienie}
  TTTableCount = Ord(High(char)) - Ord(Low(char)) +1;

type
  TVerticesTable = record
    { Sample font that requires length of p > 1000 is "Christmas Card".
      So length of p is now 10 000. }
    p: array[1..10000] of TVector3d;
    count: integer;
  end;
  PVerticesTable = ^TVerticesTable;

  procedure AddVertex(var table: TVerticesTable; const v: TVector3d);
  begin
   if table.count >= High(table.p) then
    raise EInternalError.Create('OpenGLTTFonts: too small size of '+
      'TVerticesTable.p - tesselator can''t work') else
    begin
     Inc(table.count);
     table.p[table.count] := v;
    end;
  end;

  function LastAdded(const table: TVerticesTable): PVector3d;
  begin result := @table.p[table.count] end;

procedure TessCombineCallback(Coords: PVector3d; vertex_data: Pointer;
  Weight: PVector4f; dataOut: PPointer; tablep: PVerticesTable ); OPENGL_CALLBACK_CALL
begin
 AddVertex(tablep^, Coords^);
 dataOut^ := LastAdded(tablep^);
end;

constructor TGLOutlineFont.Create(TrueTypeFont: PTrueTypeFont;
  const depth: TGLfloat;
  const onlyLines: boolean;
  const CharactersSubset: TSetOfChars);
var i, poz,
    linesCount, pointsCount :Cardinal;
    Znak: PTTFChar;
    tobj: PGLUTesselator;

    { tablica przechowujaca vertexy na ktore tesselator bedzie dostawal wskazniki. }
    vertices : PVerticesTable;

  procedure TesselatedPolygon(polZ: TGLfloat);
  var PolygonNum, LineNum, PointNum: Integer;
      PointsKind: TPolygonKind;
  begin
   vertices^.count := 0;

   gluTessBeginPolygon(tobj, vertices);
   poz := 0;
   for PolygonNum := 1 to Znak^.Info.PolygonsCount do
   begin
    { read pkNewPolygon starter }
    Assert(Znak^.items[poz].Kind = pkNewPolygon);
    linesCount := Znak^.items[poz].Count;
    Inc(poz);

    gluTessBeginContour(tobj);
    for LineNum := 1 to linesCount do
    begin
     { read pkLines/Bezier starter }
     Assert(Znak^.items[poz].Kind in [pkLines, pkBezier]);
     PointsKind := Znak^.items[poz].Kind;
     PointsCount := Znak^.items[poz].Count;
     Inc(poz);

     case PointsKind of
      pkLines,
      pkBezier:
        begin
         for PointNum := 1 to PointsCount-1 do
         begin
          with Znak^.items[poz] do
          begin
           { vertexy dla tesselatora musza byc podawane w postaci 3 x GLdouble
             (a my mamy 2 x GLfloat). Nie mozna ich tworzyc tymczasowo (za pomoca
             funkcji Vector3d, na przyklad) bo przekazujemy WSKAZNIK i glu nie kopiuje
             sobie jego zawartosci ale pozniej przekazuje do glVertex3dv zapamietany
             wskaznik. Wiec te strukturki 3 x GLdouble musza byc troche bardziej trwale
             (wskazniki musza byc poprawne az do konca tesselowania tego znaku).
             Dlatego uzywamy tablicy vertices (zwroc uwage ze tablica o dynamicznym
             rozmiarze nie jest tu dobrym rozwiazaniem bo przy kazdej alokacji
             cala tablica dynamiczna moze zostac przesunieta w inne miejsce
             pamieci. Wiec wskazniki na elementy tablicy dynamicznej nie maja
             zadnej trwalosci ! }
           AddVertex(vertices^, Vector3Double(x, y, polZ) );
           gluTessVertex(tobj,
             {$ifndef USE_OLD_OPENGLH} T3dArray ( {$endif}
             LastAdded(vertices^)
             {$ifndef USE_OLD_OPENGLH} ^) {$endif}
             , LastAdded(vertices^) );
          end;
          Inc(poz);
         end;
         Inc(poz); { ostatniego punktu linii nie czytamy - to jest pierwszy
                     punkt nastepnej linii lub pierwszy punkt polygonu }
        end;
        { TODO:  zrobic opcje ktora pozwoli na robienie tu krzywych beziera,
          jesli kiedys bedziesz potrzebowal BARDZO dokladnie wyrenderowac
          jakas literke (np. w duzym powiekszeniu) }
     end;
    end;
    gluTessEndContour(tobj);
   end;
   gluTessEndPolygon(tobj);
  end;

begin
 inherited Create;
 New(vertices);
 try
  base := glGenListsCheck(TTTableCount, 'TGLOutlineFont.Create');
  Self.TTFont := TrueTypeFont;

  tobj := gluNewTess();  { inicjuj tesselator }
  gluTessCallback(tobj, GLU_TESS_VERTEX, TCallBack(glVertex3dv));
  gluTessCallback(tobj, GLU_TESS_BEGIN, TCallBack(glBegin));
  gluTessCallback(tobj, GLU_TESS_END, TCallBack(glEnd));

  { This is a workaround of Mesa3D bug.
    See ../doc/mesa_normals_edge_flag_bug.txt }
  if not GLVersion.IsMesa then
    gluTessCallback(tobj, GLU_TESS_EDGE_FLAG, TCallBack(glEdgeFlag));

  gluTessCallback(tobj, GLU_TESS_ERROR, TCallBack(@ReportGLError));
  gluTessCallback(tobj, GLU_TESS_COMBINE_DATA, TCallBack(@TessCombineCallback));

  if onlyLines then gluTessProperty(tobj, GLU_TESS_BOUNDARY_ONLY, GL_TRUE);

  {line below speeds up the tesselation and makes sure that all letters
   have consistent winding (conterclockwise with respect to normal 0, 0, -1)}
  gluTessNormal(tobj, 0, 0, -1);

  for i := 0 to 255 do
  begin
   Znak := TTFont^[Chr(i)];
   glNewList(i+base, GL_COMPILE);

   if (CharactersSubset = []) or (Chr(i) in CharactersSubset) then
   begin
     if Depth <> 0 then glNormal3f(0, 0, -1);

     TesselatedPolygon(0);

     if depth <> 0 then
     begin
       { Draw copy of polygons on Depth. This still gets
         normal (0, 0, -1), set above for the 1st copy at Depth = 0.  }
       TesselatedPolygon(depth);

       { Draw sides. CharExtrusionPrint will produce appropriate normal vectors. }
       CharExtrusionPrint(Chr(I), Depth, onlyLines);
     end;
   end;

   glEndList;

  end;

  gluDeleteTess(tobj);

 finally Dispose(vertices) end;

 fRowHeight := TTFontSimpleRowHeight(TTFont);
end;

destructor TGLOutlineFont.Destroy;
begin
 glDeleteLists(base, TTTableCount);
 inherited;
end;

procedure TGLOutlineFont.CharPrint(c: char);
begin
 glCallList(Ord(c)+base);
end;

procedure TGLOutlineFont.CharPrintAndMove(c: char);
begin
 CharPrint(c);
 glTranslatef(TTFont^[c]^.Info.MoveX, TTFont^[c]^.Info.MoveY, 0);
end;

procedure TGLOutlineFont.Print(const s: string);
begin
 glPushMatrix;
 PrintAndMove(s);
 glPopMatrix;
end;

procedure TGLOutlineFont.PrintAndMove(const s: string);
var i: integer;
begin
 for i := 1 to Length(s) do CharPrintAndMove(s[i]);
end;

function TGLOutlineFont.TextWidth(const s: string): single;
begin result := TTFontTextWidth(TTfont, s) end;

function TGLOutlineFont.TextHeight(const s: string): single;
begin result := TTFontTextHeight(TTfont, s) end;

procedure TGLOutlineFont.TexturedBegin(const TexOriginX, TexOriginY: TGLfloat);
begin
  glPushAttrib(GL_TEXTURE_BIT);

  glTexGeni(GL_S, GL_TEXTURE_GEN_MODE, GL_OBJECT_LINEAR);
  glTexGeni(GL_T, GL_TEXTURE_GEN_MODE, GL_OBJECT_LINEAR);

  glTexGenv(GL_S, GL_OBJECT_PLANE, Vector4Single(1/RowHeight, 0, 0, - texOriginX / RowHeight));
  glTexGenv(GL_T, GL_OBJECT_PLANE, Vector4Single(0, 1/RowHeight, 0, - texOriginY));
  { texT = (objectY - texOriginY)/RowHeight =
           objectY/RowHeight - texOriginY/RowHeight

    Note that equation for GL_S above is actually the same as the one in
    TexturedLetterEnd with TexturedXShift assumed to be 0. }

  glEnable(GL_TEXTURE_GEN_S);
  glEnable(GL_TEXTURE_GEN_T);

  TexturedXShift := 0;
end;

procedure TGLOutlineFont.TexturedLetterEnd(
  const TexOriginX, TexOriginY: TGLfloat; const C: char);
begin
  TexturedXShift += TTFont^[C]^.Info.MoveX;

  { texS = (objectX+xshift - texOriginX)/RowHeight =
           objectX/RowHeight + (xshift-texOriginX)/RowHeight

    TexturedXShift sie zmienia, to jest powod dla ktorego musimy przed
    narysowaniem kazdego charactera ustawic glTexGenv(GL_S,...) od nowa }
  glTexGenv(GL_S, GL_OBJECT_PLANE,
    Vector4Single(1/RowHeight, 0, 0,
    (TexturedXShift - texOriginX) / RowHeight));
end;

procedure TGLOutlineFont.TexturedEnd;
begin
  glPopAttrib;
end;

procedure TGLOutlineFont.PrintTexturedAndMove(const s: string;
  const TexOriginX, TexOriginY: TGLfloat);
var
  i: integer;
begin
  TexturedBegin(TexOriginX, TexOriginY);
  for i := 1 to Length(s) do
  begin
    CharPrintAndMove(s[i]);
    TexturedLetterEnd(texOriginX, texOriginY, S[I]);
  end;
  TexturedEnd;
end;

procedure TGLOutlineFont.PrintTextured(const s: string;
  const texOriginX, texOriginY: TGLfloat);
begin
  glPushMatrix;
  PrintTexturedAndMove(s, texOriginX, texOriginY);
  glPopMatrix;
end;

procedure TGLOutlineFont.CharExtrusionPrint(
  const C: char; const Depth: Single; onlyLines: boolean);
var
  Znak: PTTFChar;
  Poz: Cardinal;
  PolygonNum, LineNum, PointNum: Integer;
  PointsKind: TPolygonKind;
  linesCount, pointsCount :Cardinal;
  Character, NextCharacter: PTTFCharItem;
  Normal: TVector3Single;
begin
  Znak := TTFont^[C];

  poz := 0;
  for PolygonNum := 1 to Znak^.Info.PolygonsCount do
  begin
   Assert(Znak^.items[poz].Kind = pkNewPolygon);
   linesCount := Znak^.items[poz].Count;
   Inc(poz);

   { Set Normal, only to have it initially set to anything.
     Value below will be used as normal for 2nd vertex, and for flat shading
     this will simply be ignored. }
   Normal := Vector3Single(1, 0, 0);

   if onlyLines then glBegin(GL_LINES) else glBegin(GL_QUAD_STRIP);

   for LineNum := 1 to LinesCount do
   begin
    Assert(Znak^.items[poz].Kind in [pkLines, pkBezier]);
    PointsKind := Znak^.items[poz].Kind;
    PointsCount := Znak^.items[poz].Count;
    Inc(poz);

    case PointsKind of
     pkLines,
     pkBezier:
       begin
        for PointNum := 1 to PointsCount-1 do
        begin
          { Thanks to the fact that each line always has as it's last point
            the first point of next line (or the first point of this polygon),
            we can safely assume here that Znak^.items[poz+1] is the next char. }
          Character := @Znak^.Items[poz];
          NextCharacter := @Znak^.Items[poz + 1];

          with Character^ do
          begin
            glVertex2f(x, y);
            glNormalv(Normal);
            glVertex3f(x, y, depth);
          end;

          { Calculate normal for the quad you just started now,
            it will be actually passed to glNormal in next iteration.
            Reason: For flat shading and GL_QUAD_STRIP, OpenGL says
            that the properties (like a normal) of 2i+2 vertex define
            the properties of i-th quad (counted from one).
            I other words, the normal before 4th vertex sets normal
            for 1st quad, before 6th vertex -- for 2nd quad and so on. }

          Normal := TriangleNormal(
            Vector3Single(    Character^.X,     Character^.Y, 0),
            Vector3Single(    Character^.X,     Character^.Y, Depth),
            Vector3Single(NextCharacter^.X, NextCharacter^.Y, 0));

          Inc(poz);
        end;
        Inc(poz); { ostatniego punktu linii nie czytamy - to jest pierwszy
                    punkt nastepnej linii lub pierwszy punkt polygonu }
       end;
       { TODO:  robic tu krzywe beziera jezeli kiedys bede potrzebowal
         takiej dokladnosci? }
    end;
   end;

   {na koncu - laczymy ostatnia pare z pierwsza}
   if not onlyLines then
   with Znak^.items[poz-1] do
   begin
    glVertex2f(x, y);
    glNormalv(Normal);
    glVertex3f(x, y, depth);
   end;

   glEnd;
  end;
end;

procedure TGLOutlineFont.CharExtrusionPrintAndMove(
  const C: char; const Depth: Single);
begin
  CharExtrusionPrint(C, Depth);
  glTranslatef(TTFont^[C]^.Info.MoveX, TTFont^[C]^.Info.MoveY, 0);
end;

procedure TGLOutlineFont.PrintExtrusionAndMove(
  const S: string; const Depth: Single);
var
  I: Integer;
begin
  for I := 1 to Length(S) do
    CharExtrusionPrintAndMove(S[I], Depth);
end;

procedure TGLOutlineFont.PrintTexturedExtrusionAndMove(
  const S: string; const Depth: Single;
  const TexOriginX, TexOriginY: TGLfloat);
var
  I: Integer;
begin
  TexturedBegin(TexOriginX, TexOriginY);
  for I := 1 to Length(S) do
  begin
    CharExtrusionPrintAndMove(S[I], Depth);
    TexturedLetterEnd(TexOriginX, texOriginY, S[I]);
  end;
  TexturedEnd;
end;

end.
