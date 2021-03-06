{
  Copyright 2018-2018 Michalis Kamburelis.

  This file is part of "Castle Game Engine".

  "Castle Game Engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Castle Game Engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{ Project-related castle-editor utilities. }
unit ProjectUtils;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

{ Fill directory for new project with the template. }
procedure CopyTemplate(const ProjectDirUrl: String;
  const TemplateName, ProjectName: String);

{ Fill directory for new project with the build-tool generated stuff. }
procedure GenerateProgramWithBuildTool(const ProjectDirUrl: String);

{ Open ProjectForm. }
procedure ProjectOpen(const ManifestUrl: string);

type
  TBuildMode = (bmDebug, bmRelease);

implementation

uses Forms,
  CastleURIUtils, CastleStringUtils, CastleFindFiles, CastleUtils,
  CastleFilesUtils,
  EditorUtils, ToolUtils, FormProject;

{ TTemplateCopyProcess ------------------------------------------------------------ }

type
  TTemplateCopyProcess = class
    TemplateUrl: String;
    ProjectDirUrl: String;
    Macros: TStringStringMap;
    procedure FoundFile(const FileInfo: TFileInfo; var StopSearch: Boolean);
  end;

procedure TTemplateCopyProcess.FoundFile(const FileInfo: TFileInfo; var StopSearch: Boolean);
var
  Contents, RelativeUrl, TargetUrl, TargetFileName, Mime: String;
begin
  if FileInfo.Directory and SpecialDirName(FileInfo.Name) then
    Exit;

  { Ignore case at IsPrefix / PrefixRemove calls,
    in case it's not case-sensitive file-system, then the case in theory
    can differ. }
  if not IsPrefix(TemplateUrl, FileInfo.URL, true) then
    raise Exception.CreateFmt('Unexpected: %s is not a prefix of %s, report a bug',
      [TemplateUrl, FileInfo.URL]);
  RelativeUrl := PrefixRemove(TemplateUrl, FileInfo.URL, true);
  TargetUrl := CombineURI(ProjectDirUrl, RelativeUrl);
  TargetFileName := URIToFilenameSafe(TargetUrl);

  if FileInfo.Directory then
  begin
    // create directory
    if not ForceDirectories(TargetFileName) then
      raise Exception.CreateFmt('Cannot create directory "%s"', [TargetFileName]);
  end else
  begin
    Mime := URIMimeType(FileInfo.URL);
    if (Mime = 'application/xml') or
       (Mime = 'text/plain') then
    begin
      // copy text file, replacing macros
      Contents := FileToString(FileInfo.URL);
      Contents := SReplacePatterns(Contents, Macros, false);
      StringToFile(TargetFileName, Contents);
    end else
    begin
      // simply copy other file types (e.g. sample png images in project templates)
      CheckCopyFile(URIToFilenameSafe(FileInfo.URL), TargetFileName);
    end;
  end;
end;

{ global routines ------------------------------------------------------------ }

procedure CopyTemplate(const ProjectDirUrl: String;
  const TemplateName, ProjectName: String);
var
  TemplateUrl, ProjectQualifiedName, ProjectPascalName: String;
  CopyProcess: TTemplateCopyProcess;
  Macros: TStringStringMap;
begin
  TemplateUrl := ApplicationData('project_templates/' + TemplateName + '/files/');

  ProjectQualifiedName := 'com.mycompany.' + SDeleteChars(ProjectName, ['-']);
  ProjectPascalName := SReplaceChars(ProjectName, AllChars - ['a'..'z', 'A'..'Z', '0'..'9'], '_');

  Macros := TStringStringMap.Create;
  try
    Macros.Add('${PROJECT_NAME}', ProjectName);
    Macros.Add('${PROJECT_QUALIFIED_NAME}', ProjectQualifiedName);
    Macros.Add('${PROJECT_PASCAL_NAME}', ProjectPascalName);

    CopyProcess := TTemplateCopyProcess.Create;
    try
      CopyProcess.TemplateUrl := TemplateUrl;
      CopyProcess.ProjectDirUrl := ProjectDirUrl;
      CopyProcess.Macros := Macros;
      FindFiles(TemplateUrl, '*', true, @CopyProcess.FoundFile, [ffRecursive]);
    finally FreeAndNil(CopyProcess) end;
  finally FreeAndNil(Macros) end;
end;

procedure GenerateProgramWithBuildTool(const ProjectDirUrl: String);
var
  BuildToolExe, BuildToolOutput: String;
  BuildToolStatus: integer;
begin
  BuildToolExe := FindExe('castle-engine');
  if BuildToolExe = '' then
  begin
    WarningBox('Cannot find build tool (castle-engine) on $PATH environment variable. You will need to manually run "castle-engine generate-program" within project''s directory.');
    Exit;
  end;

  MyRunCommandIndir(URIToFilenameSafe(ProjectDirUrl), BuildToolExe,
    ['generate-program'], BuildToolOutput, BuildToolStatus);
  if BuildToolStatus <> 0 then
  begin
    WarningBox(Format('Generating program with the build tool failed with status code %d and output: "%s"',
      [BuildToolStatus, BuildToolOutput]));
    Exit;
  end;
end;

procedure ProjectOpen(const ManifestUrl: string);
begin
  // Validate
  if not URIFileExists(ManifestUrl) then
    raise Exception.CreateFmt('Cannot find CastleEngineManifest.xml at this location: "%s". Invalid project opened.',
      [ManifestUrl]);

  ProjectForm := TProjectForm.Create(Application);
  ProjectForm.OpenProject(ManifestUrl);
  ProjectForm.Show;
end;

end.
