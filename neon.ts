import { defineConfig } from "@neon/config/v1";

export default defineConfig({
  // The app runs its own username + PIN logins inside the api function,
  // so Neon Auth stays off.
  auth: false,
  buckets: {
    // Question-paper page photos and question diagrams.
    uploads: { access: "private" },
  },
  functions: {
    // The whole app API (Hono). GROQ_API_KEYS is set on the function once,
    // outside this file, so deploys never carry the keys.
    api: { name: "api", source: "./api/src/index.ts" },
  },
  // The notification trigger is created with the CLI on the branches that send notifications
  // (see "Notifications" in the README), not declared here: `neon dev` refuses to run on a
  // branch that lacks a declared trigger.
  // Branch policy: per-branch tuning
  branch: (branch) => {
    if (branch.isDefault) {
      // Default branch: no overrides, uses project defaults
      return {};
    }
    if (!branch.exists) {
      // New non-default branches: auto-expire
      // Run `neon checkout <name>` to create a new branch with these settings
      return { ttl: "7d" };
    }
    // Existing branch: no changes
    return {};
  },
});
