import { handler } from '../../src/pre-token-generation/handler';

describe('pre-token-generation', () => {
  it('adds scope claims for group names', async () => {
    const result = await handler({
      version: '2',
      region: 'us-east-1',
      userPoolId: 'pool',
      userName: 'user',
      callerContext: { awsSdkVersion: '3', clientId: 'abc' },
      triggerSource: 'TokenGeneration_HostedAuth',
      request: { groupConfiguration: { groupsToOverride: ['Admin', 'Registered'] }, scopes: [] },
      response: {},
    } as any);

    expect(result.response.claimsAndScopeOverrideDetails.accessTokenGeneration.scopesToAdd).toEqual([
      'sc.group.admin',
      'sc.group.registered',
    ]);
  });
});
