import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "El Cometa - Gestión Administrativa",
  description:
    "Sistema administrativo de El Cometa para alquileres y subsistemas independientes.",
  manifest: "/manifest.webmanifest",
  icons: {
    icon: [
      { url: "/favicon-32.png", sizes: "32x32", type: "image/png" },
      { url: "/el-cometa-icon-192.png", sizes: "192x192", type: "image/png" },
      { url: "/el-cometa-icon-512.png", sizes: "512x512", type: "image/png" },
    ],
    shortcut: "/favicon-32.png",
    apple: "/apple-touch-icon.png",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="es">
      <body>{children}</body>
    </html>
  );
}
