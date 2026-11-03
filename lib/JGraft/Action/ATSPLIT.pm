package JGraft::Action::ATSPLIT;
# VERSION
# ABSTRACT: Navigate into SPLIT, apply actions, re-JOIN

=head1 DESCRIPTION

This object represents the L<ATSPLIT Action|https://github.com/nrdvana/JGraft/SpecV1.md#act-atsplit>.

The action navigates to L</path>, splits that string according to L</split_spec>, executes
L</actions> on that temporary array, and then re-joins the string using L</split_spec>.

=attribute id

The numeric operation ID, C<2>.

=attribute path

A NODE reference, or a scalar shorthand for one.

=attribute split_spec

A literal separator string, match/reference expression, or split configuration hashref.

=attribute actions

An arrayref of action operands.

=constructor new

  ->new(%attributes);
  ->new([ $path, \%split_spec, @actions ]);

Construct via attribute names or JGraft argument specification from values which are already
inflated / decoded from JGraft JSON notation.

=constructor new_from_json_data

  ->new_from_json_data(\@jgraft_json_array);

Construct from the JGraft JSON array notation, where the first element is the action name and
each subsequent argument needs recursively inflated / decoded from JGraft JSON notation.

=method to_json_data

Encode the action in JGraft JSON notation.

=cut

require JGraft::Action;

1;
