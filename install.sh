#!/bin/bash

# S'arrêter en cas d'erreur
set -e

echo "🚀 Compilation de MirrorCal pour macOS (Release)..."

# Se placer dans le dossier du projet macOS
cd "$(dirname "$0")/MirrorCal" || exit

# Nettoyer les anciens builds
rm -rf build

# Compiler le projet avec xcodebuild, en forçant le dossier de sortie dans ./build
xcodebuild \
  -project MirrorCal.xcodeproj \
  -scheme MirrorCal \
  -configuration Release \
  SYMROOT="$(pwd)/build" \
  OBJROOT="$(pwd)/build" \
  build > /dev/null

APP_PATH="build/Release/MirrorCal.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Erreur : La compilation a échoué ou l'application n'a pas été trouvée."
    exit 1
fi

echo "📦 Installation dans le dossier /Applications..."

# Supprimer l'ancienne version si elle existe
if [ -d "/Applications/MirrorCal.app" ]; then
    rm -rf "/Applications/MirrorCal.app"
    echo "Ancienne version supprimée."
fi

# Copier la nouvelle application
cp -R "$APP_PATH" /Applications/

# Nettoyer le dossier de build
rm -rf build

echo "✅ Installation terminée avec succès ! Vous pouvez lancer MirrorCal depuis le dossier Applications ou via Spotlight (⌘ Espace)."
