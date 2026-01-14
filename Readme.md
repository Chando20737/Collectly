# Collectly

Collectly est une application iOS de gestion et de mise en marché de cartes à collectionner (hockey, sports, collectibles), avec support des ventes à prix fixe, des encans et des notifications en temps réel.

Le projet combine **SwiftUI**, **SwiftData**, **Firebase** et des **Cloud Functions** pour offrir une expérience fluide, moderne et scalable.

---

## ✨ Fonctionnalités principales

- 📦 **Ma collection**
  - Gestion locale des cartes (SwiftData)
  - Photos, grading, informations détaillées

- 🛒 **Marketplace**
  - Annonces publiques
  - Ventes à prix fixe
  - Encans avec mises en temps réel

- 🔔 **Notifications push (Firebase Cloud Messaging)**
  - Nouvelle mise sur un encan
  - Surenchère
  - Encan terminé
  - Encan gagné
  - Vente conclue

- 👤 **Comptes utilisateurs**
  - Authentification Firebase
  - Username unique
  - Profil public

- ⚙️ **Automatisation serveur**
  - Fin automatique des encans expirés (cron)
  - Triggers Firestore pour notifications (bids, ventes)

---

## 🧱 Architecture

### iOS
- **SwiftUI**
- **SwiftData** (stockage local)
- **Firebase**
  - Auth
  - Firestore
  - Storage
  - Cloud Messaging (FCM)

### Backend
- **Firebase Cloud Functions (Node.js / TypeScript)**
- Fonctions Gen 2
- Triggers Firestore + Scheduler

---

## 📂 Structure du projet

```text
Collectly/
├─ Collectly/                # App iOS (SwiftUI)
│  ├─ App/
│  ├─ Views/
│  ├─ Services/
│  ├─ Models/
│  └─ Push / DeepLinks
│
├─ functions/                # Firebase Cloud Functions
│  ├─ src/
│  │  └─ index.ts
│  ├─ package.json
│  └─ tsconfig.json
│
├─ .gitignore
└─ README.md
