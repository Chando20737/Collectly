import {onObjectFinalized} from "firebase-functions/v2/storage";
import {initializeApp} from "firebase-admin/app";

initializeApp();

export const matchCard = onObjectFinalized(
  {
    cpu: 1,
    region: "us-east1",
  },
  async (event) => {
    const filePath = event.data.name;

    if (!filePath || !filePath.startsWith("temp-scans/")) {
      return null;
    }

    console.log("🔍 New card to match:", filePath);

    return null;
  }
);
