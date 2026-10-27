import type { APIRoute } from "astro";
import { markdownHandler } from "../config/markdown-documents";
export const GET: APIRoute = async () => (await markdownHandler(new Request("https://heypace.app/ai.txt")))!;
