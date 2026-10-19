import { parseFrontmatter, parseFrontmatterStrict } from './frontmatter.js';

describe('parseFrontmatter', () => {
  it('treats an empty frontmatter block as an empty mapping', () => {
    // js-yaml 5 throws on yaml.load('') — the empty block must short-circuit.
    const result = parseFrontmatter('---\n---\nbody text\n');
    expect(result.frontmatter).toEqual({});
    expect(result.tags).toEqual([]);
    expect(result.body).toBe('body text\n');
  });

  it('treats a whitespace-only frontmatter block as empty', () => {
    const result = parseFrontmatter('---\n   \n---\nbody\n');
    expect(result.frontmatter).toEqual({});
    expect(result.body).toBe('body\n');
  });

  it('parses tags from a populated block', () => {
    const result = parseFrontmatter('---\ntags: [a, b]\ntitle: t\n---\nbody\n');
    expect(result.tags).toEqual(['a', 'b']);
    expect(result.frontmatter.title).toBe('t');
    expect(result.body).toBe('body\n');
  });
});

describe('parseFrontmatterStrict', () => {
  it('treats an empty frontmatter block as an empty mapping with hasFence', () => {
    const result = parseFrontmatterStrict('---\n---\nbody text\n');
    expect(result.frontmatter).toEqual({});
    expect(result.hasFence).toBe(true);
    expect(result.body).toBe('body text\n');
  });
});
