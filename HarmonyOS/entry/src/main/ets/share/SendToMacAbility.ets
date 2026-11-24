import { ShareExtensionAbility, UIExtensionContentSession, Want } from '@kit.AbilityKit';
import { FileTransferClient } from '../roundtrip/FileTransferClient';

export default class SendToMacAbility extends ShareExtensionAbility {
  async onSessionCreate(want: Want, session: UIExtensionContentSession): Promise<void> {
    const uris = await FileTransferClient.sharedSources(want);
    const storage = new LocalStorage();
    storage.setOrCreate('shareSession', session);
    storage.setOrCreate('shareContext', this.context);
    storage.setOrCreate('shareURIs', uris);
    session.loadContent('pages/SendToMac', storage);
  }
}
