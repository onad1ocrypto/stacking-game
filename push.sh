#!/bin/bash
cd "$(dirname "$0")"

MESSAGE="${1:-Update project ($(date '+%Y-%m-%d %H:%M'))}"

echo "📦 Menambahkan semua perubahan..."
git add .

echo "💾 Commit dengan pesan: $MESSAGE"
git commit -m "$MESSAGE"

echo "🚀 Push ke GitHub..."
git push

echo "✅ Selesai! Vercel bakal auto-deploy dalam ~30 detik."
