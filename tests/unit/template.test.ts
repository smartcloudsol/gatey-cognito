import { interpolateTemplate } from '../../src/shared/template';

describe('interpolateTemplate', () => {
  it('replaces moustache placeholders', () => {
    expect(interpolateTemplate('Hello {{name}}', { name: 'László' })).toBe('Hello László');
  });
});
