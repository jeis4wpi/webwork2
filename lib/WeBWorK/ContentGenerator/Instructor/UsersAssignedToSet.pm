package WeBWorK::ContentGenerator::Instructor::UsersAssignedToSet;
use Mojo::Base 'WeBWorK::ContentGenerator', -signatures;

=head1 NAME

WeBWorK::ContentGenerator::Instructor::UsersAssignedToSet - List and edit the
users to which sets are assigned.

=cut

use WeBWorK::Debug;
use WeBWorK::Utils::Instructor qw(assignSetToAllUsers assignSetToGivenUsers);
use WeBWorK::Utils::Sets       qw(format_set_name_display);

sub initialize ($c) {
	my $authz = $c->authz;
	my $db    = $c->db;
	my $setID = $c->stash('setID');
	my $user  = $c->param('user');

	# Make sure these are defined for the template.
	$c->stash->{user_records} = [];
	$c->stash->{set_records}  = {};

	# Check permissions
	return unless $authz->hasPermissions($user, "access_instructor_tools");
	return unless $authz->hasPermissions($user, "assign_problem_sets");

	my %selectedUsers = map { $_ => 1 } $c->param('selected');

	my $doAssignToSelected = 0;

	if (defined $c->param('assignToAll')) {
		debug("assignSetToAllUsers($setID)");
		$c->addgoodmessage($c->maketext("Problems have been assigned to all current users."));
		assignSetToAllUsers($db, $c->ce, $setID);
		debug("done assignSetToAllUsers($setID)");
	} elsif (defined $c->param('unassignFromAll')
		&& defined($c->param('unassignFromAllSafety'))
		&& $c->param('unassignFromAllSafety') == 1)
	{
		%selectedUsers = ();
		$c->addgoodmessage($c->maketext("Problems for all students have been unassigned."));
		$doAssignToSelected = 1;
	} elsif (defined $c->param('assignToSelected')) {
		$c->addgoodmessage($c->maketext("Problems for selected students have been reassigned."));
		$doAssignToSelected = 1;
	} elsif (defined $c->param("unassignFromAll")) {
		# no action taken
		$c->addbadmessage($c->maketext("No action taken"));
	}

	# Get all user records and cache them for later use.
	$c->stash->{user_records} =
		[ $db->getUsersWhere({ user_id => { not_like => 'set_id:%' } }, [qw/section last_name first_name/]) ];

	if ($doAssignToSelected) {
		my $setRecord = $db->getGlobalSet($setID);
		die "Unable to get global set record for $setID " unless $setRecord;

		my %setUsers = map { $_ => 1 } $db->listSetUsers($setID);
		my @usersToAdd;
		for my $selectedUser (map { $_->user_id } @{ $c->stash->{user_records} }) {
			if (exists $selectedUsers{$selectedUser}) {
				unless ($setUsers{$selectedUser}) {    # skip users already in the set
					debug("saving $selectedUser to be added to set later");
					push(@usersToAdd, $selectedUser);
				}
			} else {
				next unless $setUsers{$selectedUser};    # skip users not in the set
				$db->deleteUserSet($selectedUser, $setID);
			}
		}
		if (@usersToAdd) {
			debug("assignSetToGivenUsers(...)");
			assignSetToGivenUsers($db, $c->ce, $setID, 1, $db->getUsers(@usersToAdd));
			debug("done assignSetToGivenUsers(...)");
		}
	}

	$c->stash->{set_records} = { map { $_->user_id => $_ } $db->getUserSetsWhere({ set_id => $setID }) };

	return;
}

1;
