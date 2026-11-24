import home from "../content/home.json";

const faq = home.sections.find((section) => section.id === "faq")?.blocks.find((block) => block.type === "faq");
if (!faq || !("items" in faq) || !faq.items) throw new Error("Missing homepage FAQ");
export const qas = faq.items;
