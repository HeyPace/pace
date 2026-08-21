import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest(async () => ({
      remoteBindings: false,
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          TEST_MIGRATIONS: await readD1Migrations("./migrations"),
        },
        serviceBindings: {
          CALORIE_SERVICE: async (request) => calorieResponse(request),
        },
      },
    })),
  ],
  test: {
    setupFiles: ["./test/apply-migrations.ts"],
  },
});

interface ServiceRequest {
  readonly url: string;
  readonly method: string;
  readonly headers: { get(name: string): string | null };
  json(): Promise<unknown>;
}

async function calorieResponse(request: ServiceRequest): Promise<Response> {
  const url = new URL(request.url);
  if (request.headers.get("authorization") !== "Bearer calorie-session-token") {
    return Response.json({ message: "unauthorized" }, { status: 401 });
  }
  if (url.pathname === "/api/auth/get-session") {
    return Response.json({ user: { id: "calorie-auth-user", email: "pace@example.com" } });
  }
  if (url.pathname === "/api/auth/list-accounts") {
    return Response.json([{ providerId: "apple", accountId: "apple-subject" }]);
  }
  if (request.method === "GET" && url.pathname === "/api/app/dashboard") {
    return Response.json({
      totals: { calories: 640, protein: 42 },
      targets: { calories: 2_000, protein: 120 },
      foods: [{ id: "usual-breakfast", name: "Usual breakfast", defaultAmount: 1 }],
    });
  }
  if (request.method === "POST" && url.pathname === "/api/app/entries") {
    const body = (await request.json()) as { id: string };
    return Response.json({ id: body.id, foodName: "Usual breakfast" }, { status: 201 });
  }
  if (request.method === "DELETE" && url.pathname.startsWith("/api/app/entries/")) {
    return new Response(null, { status: 204 });
  }
  return Response.json({ message: "not found" }, { status: 404 });
}
