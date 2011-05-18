{
  Copyright 2008-2010 Michalis Kamburelis.

  This file is part of "Kambi VRML game engine".

  "Kambi VRML game engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Kambi VRML game engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{ Pass on command-line the filename ("-" means stdin) of 3D model file.
  If this file was generated by the standard Blender VRML 1.0, 2.0 or
  X3D exporter, we will output Blender object and mesh names, if available,
  for shapes inside.

  This is useful if your game wants to use Blender object / mesh names,
  for whatever purpose (for example, maybe you want to mark by special
  names some objects in Blender, and you want to detect this inside the game). }
program test_blender_exported_hierarchy;

uses SysUtils, KambiUtils, VRMLShape, VRMLScene;

procedure Traverse(Shape: TVRMLShape);
begin
  Writeln(
    'Blender object "', Shape.BlenderObjectName, '" (VRML/X3D ', Shape.BlenderObjectNode.NodeTypeName, ') -> ' +
              'mesh "', Shape.BlenderMeshName, '" (VRML/X3D ', Shape.BlenderMeshNode.NodeTypeName, ')');
end;

var
  Scene: TVRMLScene;
  SI: TVRMLShapeTreeIterator;
begin
  Scene := TVRMLScene.Create(nil);
  try
    Scene.Load(Parameters[1], true);

    SI := TVRMLShapeTreeIterator.Create(Scene.Shapes, { OnlyActive } true);
    try
      while SI.GetNext do Traverse(SI.Current);
    finally FreeAndNil(SI) end;
  finally FreeAndNil(Scene) end;
end.