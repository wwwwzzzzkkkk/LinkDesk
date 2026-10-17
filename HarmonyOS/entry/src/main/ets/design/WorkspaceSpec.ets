import { DT, Strings } from './GeneratedDesign';

export class WorkspaceSpec {
  static readonly order: string[] = ['home', 'display', 'pdf', 'whiteboard', 'mirror'];
  static title(key: string): string {
    switch (key) {
      case 'display': return Strings.displayTitle;
      case 'pdf': return Strings.pdfTitle;
      case 'whiteboard': return Strings.whiteboardTitle;
      case 'mirror': return Strings.mirrorTitle;
      default: return Strings.homeTitle;
    }
  }
  static subtitle(key: string): string {
    switch (key) {
      case 'display': return Strings.displaySubtitle;
      case 'pdf': return Strings.pdfSubtitle;
      case 'whiteboard': return Strings.whiteboardSubtitle;
      case 'mirror': return Strings.mirrorSubtitle;
      default: return Strings.homeSubtitle;
    }
  }
  static icon(key: string): Resource {
    switch (key) {
      case 'display': return DT.iconDisplay;
      case 'pdf': return DT.iconPdf;
      case 'whiteboard': return DT.iconWhiteboard;
      case 'mirror': return DT.iconMirror;
      default: return DT.iconHome;
    }
  }
}
