export function interpolateTemplate(
  template: string,
  variables: Record<string, string | undefined>,
): string {
  return template.replace(/\{\{([a-zA-Z0-9_]+)\}\}/g, (_m, key) => variables[key] ?? "");
}
