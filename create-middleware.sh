#!/bin/sh

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "🔍 Détection du type de projet..."

if [ -f "next.config.mjs" ]; then
  echo "${GREEN}✅ Projet Next.js détecté.${NC}"
  mkdir -p middleware
  cat <<EOF > middleware/logger.js
// middleware/logger.js - Next.js Middleware
import { NextResponse } from 'next/server'

export function middleware(request) {
  console.log("🔄 Requête interceptée:", request.url)
  return NextResponse.next()
}

export const config = {
  matcher: ['/((?!_next|favicon.ico).*)'],
}
EOF
  echo "${GREEN}✅ Middleware Next.js créé dans middleware/logger.js${NC}"

elif [ -f "netlify.toml" ] || [ -d "netlify/functions" ]; then
  echo "${GREEN}✅ Projet Netlify détecté.${NC}"
  mkdir -p netlify/middleware

  cat <<EOF > netlify/middleware/auth.ts
// netlify/middleware/auth.ts - Middleware d'authentification Netlify
import { Context } from "@netlify/functions";
import jwt from "jsonwebtoken";

// Contexte étendu local à ce fichier
interface ExtendedContext extends Context {
  userData?: any;
}

export const auth = (
  handler: (request: Request, context: ExtendedContext) => Promise<Response>
) => {
  return async (request: Request, context: Context): Promise<Response> => {
    console.log("Auth middleware called");

    const authHeader =
      request.headers.get("authorization") ||
      request.headers.get("Authorization");

    const JWT_SECRET = process.env.JWT_SECRET;

    if (!JWT_SECRET) {
      return new Response(
        JSON.stringify({ error: "Erreur serveur : clé secrète manquante" }),
        { status: 500 }
      );
    }

    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "Token manquant ou invalide" }),
        { status: 401 }
      );
    }

    const token = authHeader.replace("Bearer ", "");

    try {
      const userData = jwt.verify(token, JWT_SECRET);
      const extendedContext: ExtendedContext = { ...context, userData };
      return await handler(request, extendedContext);
    } catch {
      return new Response(
        JSON.stringify({ error: "Token invalide ou expiré" }),
        { status: 401 }
      );
    }
  };
};
EOF

  echo "${GREEN}✅ Middleware Netlify (auth) créé dans netlify/middleware/auth.ts${NC}"

else
  echo "${RED}❌ Projet non reconnu (ni Next.js ni Netlify).${NC}"
  exit 1
fi
