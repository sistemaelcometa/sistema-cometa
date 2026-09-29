import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  env: {
    NEXT_PUBLIC_APP_TIME_ZONE:
      process.env.NEXT_PUBLIC_APP_TIME_ZONE ?? "America/Argentina/Buenos_Aires",
  },
};

export default nextConfig;
