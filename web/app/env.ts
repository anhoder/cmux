import { createEnv } from "@t3-oss/env-nextjs";
import { z } from "zod";

export const env = createEnv({
  server: {
    RESEND_API_KEY: z.string().min(1),
    CMUX_FEEDBACK_FROM_EMAIL: z.string().email(),
    CMUX_FEEDBACK_RATE_LIMIT_ID: z.string().min(1),
    NEXT_PUBLIC_STACK_PROJECT_ID: z.string().min(1),
    NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: z.string().min(1),
    STACK_SECRET_SERVER_KEY: z.string().min(1),
    // Mobile sync
    NEXT_PUBLIC_CONVEX_URL: z.string().url().optional(),
    CONVEX_DEPLOY_KEY: z.string().min(1).optional(),
    MOBILE_MACHINE_JWT_SECRET: z.string().min(1).optional(),
  },
  runtimeEnv: {
    RESEND_API_KEY: process.env.RESEND_API_KEY,
    CMUX_FEEDBACK_FROM_EMAIL: process.env.CMUX_FEEDBACK_FROM_EMAIL,
    CMUX_FEEDBACK_RATE_LIMIT_ID: process.env.CMUX_FEEDBACK_RATE_LIMIT_ID,
    NEXT_PUBLIC_STACK_PROJECT_ID: process.env.NEXT_PUBLIC_STACK_PROJECT_ID,
    NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY,
    STACK_SECRET_SERVER_KEY: process.env.STACK_SECRET_SERVER_KEY,
    NEXT_PUBLIC_CONVEX_URL: process.env.NEXT_PUBLIC_CONVEX_URL,
    CONVEX_DEPLOY_KEY: process.env.CONVEX_DEPLOY_KEY,
    MOBILE_MACHINE_JWT_SECRET: process.env.MOBILE_MACHINE_JWT_SECRET,
  },
  skipValidation:
    process.env.SKIP_ENV_VALIDATION === "1" ||
    process.env.VERCEL_ENV === "preview",
});
