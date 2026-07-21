import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Pointer Magic Lab — Five Working Experiments",
  description:
    "Five working pointer experiments across relationships, patterns, time, evidence, and memory.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
