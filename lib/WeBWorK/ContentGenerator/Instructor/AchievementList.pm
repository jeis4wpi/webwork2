package WeBWorK::ContentGenerator::Instructor::AchievementList;
use Mojo::Base 'WeBWorK::ContentGenerator', -signatures;

=head1 NAME

WeBWorK::ContentGenerator::Instructor::ProblemAchievementList - Entry point for achievement specific
data editing/viewing

=cut

=for comment

What do we want to be able to do here?

-select achievements to edit and then edit their "basic data".  We should also be presented with
links to edit the evaluator and the individual user data.

-assign users to achievements "en masse"

-import achievements from a file

-export achievements form a file

-collect achievement "scores" and output to a file

-create and copy achievements

-delete achievements

=cut

use Mojo::File;
use Text::CSV;

use WeBWorK::Utils        qw(sortAchievements x);
use WeBWorK::Utils::Files qw(surePathToFile);

# Forms
use constant EDIT_FORMS   => [qw(save_edit cancel_edit)];
use constant VIEW_FORMS   => [qw(filter edit assign import export score create delete)];
use constant EXPORT_FORMS => [qw(save_export cancel_export)];

# Prepare the tab titles for translation by maketext
use constant FORM_TITLES => {
	save_edit     => x('Save Edit'),
	cancel_edit   => x('Cancel Edit'),
	filter        => x('Filter'),
	edit          => x('Edit'),
	assign        => x('Assign'),
	import        => x('Import'),
	export        => x('Export'),
	score         => x('Score'),
	create        => x('Create'),
	delete        => x('Delete'),
	save_export   => x('Save Export'),
	cancel_export => x('Cancel Export')
};

sub initialize ($c) {
	my $db            = $c->db;
	my $ce            = $c->ce;
	my $authz         = $c->authz;
	my $courseName    = $c->stash('courseID');
	my $achievementID = $c->stash('achievementID');
	my $user          = $c->param('user');

	# Make sure these are available in the templates.
	$c->stash->{formsToShow}  = VIEW_FORMS();
	$c->stash->{formTitles}   = FORM_TITLES();
	$c->stash->{achievements} = [];
	$c->stash->{axpList}      = [];

	# Check permissions
	return unless $authz->hasPermissions($user, 'edit_achievements');

	# Set initial values for state fields
	my @allAchievementIDs = $db->listAchievements;

	my @users = $db->listUsers;
	$c->{allAchievementIDs} = \@allAchievementIDs;
	$c->{totalUsers}        = scalar @users;

	$c->{selectedAchievementIDs} = [ $c->param('selected_achievements') ];

	$c->{editMode} = $c->param('editMode') || 0;

	if (defined $c->param('visible_achievements')) {
		$c->{visibleAchievementIDs} = [ $c->param('visible_achievements') ];
	} elsif (defined $c->param('no_visible_achievements')) {
		$c->{visibleAchievementIDs} = [];
	} else {
		$c->{visibleAchievementIDs} = $c->{allAchievementIDs};
	}

	# Call action handler
	my $actionID = $c->param('action');
	$c->{actionID} = $actionID;
	if ($actionID) {
		unless (grep { $_ eq $actionID } @{ VIEW_FORMS() }, @{ EDIT_FORMS() }, @{ EXPORT_FORMS() }) {
			die "Action $actionID not found";
		}

		my $actionHandler = "${actionID}_handler";
		my ($success, $action_result) = $c->$actionHandler;
		if ($success) {
			$c->addgoodmessage($c->b($action_result));
		} else {
			$c->addbadmessage($c->b($action_result));
		}
	}

	$c->stash->{formsToShow} = $c->{editMode} ? EDIT_FORMS() : $c->{exportMode} ? EXPORT_FORMS() : VIEW_FORMS();
	$c->stash->{axpList}     = [ $c->getAxpList ] unless $c->{editMode} || $c->{exportMode};

	# Get and sort achievements. Achievements are sorted by in the order they are evaluated.
	$c->stash->{achievements} =
		$c->{showAllAchievements}
		? [ sortAchievements($c->db->getAchievements(@{ $c->{allAchievementIDs} })) ]
		: [ sortAchievements($c->db->getAchievements(@{ $c->{visibleAchievementIDs} })) ];

	return;
}

# Actions handlers.
# The forms for all of the actions are templates.
# filter, edit, cancel_edit, and save_edit should stay with the display module and
# not be real "actions". that way, all actions are shown in view mode and no
# actions are shown in edit mode.

sub filter_handler ($c) {
	my $db    = $c->db;
	my $scope = $c->param('action.filter.scope');
	my $result;

	if ($scope eq 'all') {
		$result = $c->maketext('Showing all achievements.');
		$c->{visibleAchievementIDs} = $c->{allAchievementIDs};
	} elsif ($scope eq 'selected') {
		$result = $c->maketext('Showing selected achievements.');
		$c->{visibleAchievementIDs} = [ $c->param('selected_achievements') ];
	} elsif ($scope eq 'match_ids') {
		$result = $c->maketext('Showing matching achievements.');
		my $terms = join('|', split(/\s*,\s*/, $c->param('action.filter.achievement_ids')));
		$c->{visibleAchievementIDs} = [ grep {/$terms/i} @{ $c->{allAchievementIDs} } ];
	} elsif ($scope eq 'match_category') {
		my $category = $c->param('action.filter.category') // '';
		$c->{visibleAchievementIDs} = [ map { $_->[0] } $db->listAchievementsWhere({ category => $category }) ];
		if (@{ $c->{visibleAchievementIDs} }) {
			$result = $c->maketext('Showing achievements in category [_1].', $category);
		} else {
			$result = $c->maketext('No achievements in category [_1].', $category);
		}
	} elsif ($scope eq 'enabled') {
		$result = $c->maketext('Showing enabled achievements.');
		$c->{visibleAchievementIDs} = [ map { $_->[0] } $db->listAchievementsWhere({ enabled => 1 }) ];
	} elsif ($scope eq 'disabled') {
		$result = $c->maketext('Showing disabled achievements.');
		$c->{visibleAchievementIDs} = [ map { $_->[0] } $db->listAchievementsWhere({ enabled => 0 }) ];
	}

	return (1, $result);
}

# Handler for editing achievements.  Just changes the view mode.
sub edit_handler ($c) {
	my $result;

	my $scope = $c->param('action.edit.scope');
	if ($scope eq "all") {
		$c->{selectedAchievementIDs} = $c->{allAchievementIDs};
		$result                      = $c->maketext('Editing all achievements.');
		$c->{showAllAchievements}    = 1;
	} elsif ($scope eq "selected") {
		$result = $c->maketext('Editing selected achievements.');
	}
	$c->{editMode} = 1;

	return (1, $result);
}

# Handler for assigning achievements to users
sub assign_handler ($c) {
	my $db             = $c->db;
	my $overwrite      = $c->param('action.assign.overwrite') eq 'everything';
	my $scope          = $c->param('action.assign.scope');
	my @achievementIDs = $scope eq 'all' ? @{ $c->{allAchievementIDs} } : @{ $c->{selectedAchievementIDs} };

	my @users        = $db->listUsers;
	my @achievements = $db->getAchievements(@achievementIDs);

	# Enable all achievements.
	for my $achievement (@achievements) { $achievement->enabled(1); }
	$db->Achievement->update_records(\@achievements) if @achievements;

	# Assign globalUserAchievement data, overwriting if necessary.
	my (@globalAchievementRecordsToAdd, @globalAchievementRecordsToPut);
	my %existingGlobalUserAchievements = map { $_ => 1 } $db->listGlobalUserAchievements;
	for my $user (@users) {
		my $globalUserAchievement = $db->newGlobalUserAchievement(user_id => $user);
		if (!$existingGlobalUserAchievements{$user}) {
			push(@globalAchievementRecordsToAdd, $globalUserAchievement);
		} elsif ($overwrite) {
			push(@globalAchievementRecordsToPut, $globalUserAchievement);
		}
	}
	$db->GlobalUserAchievement->insert_records(\@globalAchievementRecordsToAdd) if @globalAchievementRecordsToAdd;
	$db->GlobalUserAchievement->update_records(\@globalAchievementRecordsToPut) if @globalAchievementRecordsToPut;

	# Assign userAchievement data, overwriting if necessary.
	my (@userAchievementRecordsToAdd, @userAchievementRecordsToPut);
	for my $achievementID (@achievementIDs) {
		my %existingUserAchievements =
			map { $_->[0] => 1 } $db->listUserAchievementsWhere({ achievement_id => $achievementID });
		for my $user (@users) {
			my $userAchievement = $db->newUserAchievement(user_id => $user, achievement_id => $achievementID);
			if (!$existingUserAchievements{$user}) {
				push(@userAchievementRecordsToAdd, $userAchievement);
			} elsif ($overwrite) {
				push(@userAchievementRecordsToPut, $userAchievement);
			}
		}
	}
	$db->UserAchievement->insert_records(\@userAchievementRecordsToAdd) if @userAchievementRecordsToAdd;
	$db->UserAchievement->update_records(\@userAchievementRecordsToPut) if @userAchievementRecordsToPut;

	return (1, $c->maketext('Assigned achievements to users.'));
}

# Handler for scoring
sub score_handler ($c) {
	my $ce                  = $c->ce;
	my $db                  = $c->db;
	my $courseName          = $c->stash('courseID');
	my $scope               = $c->param('action.score.scope');
	my @achievementsToScore = $scope eq 'all' ? @{ $c->{allAchievementIDs} } : $c->param('selected_achievements');

	# First get everything that is needed from the database.
	my @achievements = sortAchievements($db->getAchievements(@achievementsToScore));
	my @users        = $db->getUsersWhere({ user_id => { not_like => 'set_id:%' } }, [qw(section last_name)]);

	my %globalUserAchievements = map { $_->user_id => $_ } $db->getGlobalUserAchievementsWhere;

	my %userAchievements;
	for (@achievements) {
		$userAchievements{ $_->user_id }{ $_->achievement_id } = $_
			for $db->getUserAchievementsWhere({ achievement_id => $_->achievement_id });
	}

	# Define file name
	my $scoreFileName = $courseName . '_achievement_scores.csv';
	my $scoreFilePath = $ce->{courseDirs}{scoring} . '/' . $scoreFileName;

	# Back up existing file
	if (-e $scoreFilePath) {
		rename($scoreFilePath, "$scoreFilePath.bak")
			or warn "Existing file $scoreFilePath could not be backed up and was lost.";
	}

	# Check path and open the file
	$scoreFilePath = surePathToFile($ce->{courseDirs}{scoring}, $scoreFilePath);

	my $scoreFile = Mojo::File->new($scoreFilePath)->open('>:encoding(UTF-8)')
		or return (0, $c->maketext('Failed to open [_1]', $scoreFilePath));

	# Print out header info
	print $scoreFile $c->maketext('username, last name, first name, section, achievement level, achievement score,');

	for my $achievement (@achievements) {
		print $scoreFile $achievement->achievement_id . ', ';
	}
	print $scoreFile "\n";

	# Print out achievement information for each user
	for my $userRecord (@users) {
		my $user_id = $userRecord->user_id;
		next if !$globalUserAchievements{$user_id} || $userRecord->{status} eq 'D' || $userRecord->{status} eq 'A';

		print $scoreFile "$user_id, $userRecord->{last_name}, $userRecord->{first_name}, $userRecord->{section}, ";

		my $level_id = $globalUserAchievements{$user_id}->level_achievement_id || ' ';
		my $points   = $globalUserAchievements{$user_id}->achievement_points   || 0;
		print $scoreFile "$level_id, $points, ";

		for my $achievement (@achievements) {
			my $achievement_id = $achievement->achievement_id;
			if ($userAchievements{$user_id}{$achievement_id}) {
				print $scoreFile $userAchievements{$user_id}{$achievement_id}->earned ? '1, ' : '0, ';
			} else {
				print $scoreFile ', ';
			}
		}

		print $scoreFile "\n";
	}

	$scoreFile->close;

	# Include a download link
	return (
		1,
		$c->b($c->maketext(
			'Achievement scores saved to [_1].',
			$c->link_to(
				$scoreFileName => $c->systemLink(
					$c->url_for('instructor_file_manager'),
					params =>
						{ action => 'View', files => "${courseName}_achievement_scores.csv", pwd => 'scoring' }
				)
			)
		))
	);
}

# Handler for delete action
sub delete_handler ($c) {
	my $db      = $c->db;
	my $confirm = $c->param('action.delete.confirm');

	return (1, $c->maketext('Deleted [quant,_1,achievement].', 0)) unless ($confirm eq 'yes');

	my @achievementIDsToDelete = @{ $c->{selectedAchievementIDs} };
	my %allAchievementIDs      = map { $_ => 1 } @{ $c->{allAchievementIDs} };
	my %selectedAchievementIDs = map { $_ => 1 } @{ $c->{selectedAchievementIDs} };

	# Iterate over selected achievements and delete.
	for my $achievementID (@achievementIDsToDelete) {
		delete $allAchievementIDs{$achievementID};
		delete $selectedAchievementIDs{$achievementID};

		$db->deleteAchievement($achievementID);
	}

	# Update local fields
	$c->{allAchievementIDs}      = [ keys %allAchievementIDs ];
	$c->{selectedAchievementIDs} = [ keys %selectedAchievementIDs ];

	return (1, $c->maketext('Deleted [quant,_1,achievement].', scalar @achievementIDsToDelete));
}

# Handler for creating an achievement
sub create_handler ($c) {
	my $db   = $c->db;
	my $ce   = $c->ce;
	my $user = $c->param('user');

	# Create achievement
	my $newAchievementID = $c->param('action.create.id');
	return (0, $c->maketext("Failed to create new achievement: no achievement ID specified!"))
		unless $newAchievementID =~ /\S/;
	return (0, $c->maketext("Achievement [_1] exists.  No achievement created.", $newAchievementID))
		if $db->existsAchievement($newAchievementID);
	my $newAchievementRecord = $db->newAchievement;
	my $oldAchievementID     = $c->{selectedAchievementIDs}->[0];

	my $type = $c->param('action.create.type');

	# Either assign empty data or copy over existing data
	if ($type eq "empty") {
		$newAchievementRecord->achievement_id($newAchievementID);
		$newAchievementRecord->enabled(0);
		$newAchievementRecord->assignment_type('default');
		$newAchievementRecord->test('blankachievement.at');
		$db->addAchievement($newAchievementRecord);
	} elsif ($type eq "copy") {
		return (0, $c->maketext("Failed to duplicate achievement: no achievement selected for duplication!"))
			unless $oldAchievementID =~ /\S/;
		$newAchievementRecord = $db->getAchievement($oldAchievementID);
		$newAchievementRecord->achievement_id($newAchievementID);
		$db->addAchievement($newAchievementRecord);

	}

	# Assign achievement to current user
	my $userAchievement = $db->newUserAchievement();
	$userAchievement->user_id($user);
	$userAchievement->achievement_id($newAchievementID);
	$db->addUserAchievement($userAchievement);

	# Add to local list of achievements
	push @{ $c->{allAchievementIDs} },     $newAchievementID;
	push @{ $c->{visibleAchievementIDs} }, $newAchievementID;

	return (0, $c->maketext("Failed to create new achievement: [_1]", $@)) if $@;

	return (1, $c->maketext('Successfully created new achievement [_1]', $newAchievementID));
}

# Handler for importing achievements
sub import_handler ($c) {
	my $ce = $c->ce;
	my $db = $c->db;

	my $fileName              = $c->param('action.import.source');
	my $assign                = $c->param('action.import.assign');
	my @users                 = $db->listUsers;
	my %allAchievementIDs     = map { $_ => 1 } @{ $c->{allAchievementIDs} };
	my %visibleAchievementIDs = map { $_ => 1 } @{ $c->{visibleAchievementIDs} };
	my $filePath              = $ce->{courseDirs}{achievements} . '/' . $fileName;

	my @userAchievementRecordsToAdd;

	# Open file name
	my $fh = Mojo::File->new($filePath)->open('<:encoding(UTF-8)')
		or return (0, $c->maketext("Failed to open [_1]", $filePath));

	# Read in lines from file
	my $count = 0;
	my $csv   = Text::CSV->new();
	while (my $data = $csv->getline($fh)) {
		my $achievement_id = $$data[0];

		# Add imported achievement to visible list even if it already exists.
		$visibleAchievementIDs{$achievement_id} = 1;

		# Skip achievements that already exist
		next if $db->existsAchievement($achievement_id);

		# Write achievement data.  The "format" for this isn't written down anywhere (!)
		my $achievement = $db->newAchievement();

		$achievement->achievement_id($achievement_id);

		$achievement->name($$data[1]);
		$achievement->number($$data[2]);
		$achievement->category($$data[3]);
		$achievement->assignment_type($$data[4]);
		$achievement->description($$data[5]);
		$achievement->points($$data[6]);
		$achievement->max_counter($$data[7]);
		$achievement->test($$data[8]);
		$achievement->icon($$data[9]);
		$achievement->email_template($$data[10] // '');

		$achievement->enabled($assign eq "all" ? 1 : 0);

		# Add achievement
		$db->addAchievement($achievement);
		$count++;
		$allAchievementIDs{$achievement_id} = 1;

		# Assign to users if necessary.
		if ($assign eq "all") {
			for my $user (@users) {
				my $userAchievement = $db->newUserAchievement();
				$userAchievement->user_id($user);
				$userAchievement->achievement_id($achievement_id);
				push(@userAchievementRecordsToAdd, $userAchievement);
			}
		}
	}

	$fh->close;

	# If achievements are going to be assigned, then add global user achievements
	# for users for which they do not already exist.
	if (@userAchievementRecordsToAdd) {
		my @globalAchievementRecordsToAdd;
		my %existingGlobalUserAchievements = map { $_ => 1 } $db->listGlobalUserAchievements;
		for my $user (@users) {
			next if $existingGlobalUserAchievements{$user};
			my $globalUserAchievement = $db->newGlobalUserAchievement(user_id => $user);
			push(@globalAchievementRecordsToAdd, $globalUserAchievement);
		}
		$db->GlobalUserAchievement->insert_records(\@globalAchievementRecordsToAdd) if @globalAchievementRecordsToAdd;
	}

	# Actually perform the assignments of the added achievements if there are any to assign.
	$db->UserAchievement->insert_records(\@userAchievementRecordsToAdd) if @userAchievementRecordsToAdd;

	$c->{allAchievementIDs}     = [ keys %allAchievementIDs ];
	$c->{visibleAchievementIDs} = [ keys %visibleAchievementIDs ];
	return (1, $c->maketext('Imported [quant,_1,achievement].', $count));
}

# Export handler
# This does not actually export any files, rather it sends us to a new page in order to export the files.
sub export_handler ($c) {
	my $result;

	my $scope = $c->param('action.export.scope');
	if ($scope eq "all") {
		$result                      = $c->maketext('Exporting all achievements.');
		$c->{selectedAchievementIDs} = $c->{allAchievementIDs};
		$c->{showAllAchievements}    = 1;
	} else {
		$result = $c->maketext('Exporting selected achievements.');
		$c->{selectedAchievementIDs} = [ $c->param('selected_achievements') ];
	}
	$c->{exportMode} = 1;

	return (1, $result);
}

# Handler for leaving the export page.
sub cancel_export_handler ($c) {
	$c->{exportMode} = 0;

	return (0, $c->maketext('Export abandoned.'));
}

# Handler actually exporting achievements.
sub save_export_handler ($c) {
	my $ce         = $c->ce;
	my $db         = $c->db;
	my $courseName = $c->stash('courseID');

	my @achievementIDsToExport = @{ $c->{selectedAchievementIDs} };

	# Get file path
	my $FileName = "${courseName}_achievements.axp";
	my $FilePath = "$ce->{courseDirs}{achievements}/$FileName";

	# Back up existing file
	if (-e $FilePath) {
		rename($FilePath, "$FilePath.bak")
			or warn "Existing file $FilePath could not be backed up and was lost.";
	}

	$FilePath = surePathToFile($ce->{courseDirs}{achievements}, $FilePath);

	my $fh = Mojo::File->new($FilePath)->open('>:encoding(UTF-8)')
		or return (0, $c->maketext('Failed to open [_1].', $FilePath));

	my $csv = Text::CSV->new({ eol => "\n" });

	# Iterate over achievements outputing data as csv list.  This format is not documented anywhere.
	for my $achievement ($db->getAchievements(@achievementIDsToExport)) {
		my $line = [
			$achievement->achievement_id, $achievement->name,            $achievement->number,
			$achievement->category,       $achievement->assignment_type, $achievement->description,
			$achievement->points,         $achievement->max_counter,     $achievement->test,
			$achievement->icon,
		];

		warn('Error Exporting Achievement ' . $achievement->achievement_id)
			unless $csv->print($fh, $line);
	}

	$fh->close;

	$c->{exportMode} = 0;

	return (1, $c->maketext('Exported achievements to [_1].', $FileName));
}

# Handler for cancelling edits.
sub cancel_edit_handler ($c) {
	$c->{editMode} = 0;
	return (1, $c->maketext('Changes abandoned.'));
}

# Handler for saving edits.
sub save_edit_handler ($c) {
	my $db = $c->db;

	my @selectedAchievementIDs = @{ $c->{selectedAchievementIDs} };

	for my $achievementID (@selectedAchievementIDs) {
		my $Achievement = $db->getAchievement($achievementID);

		# FIXME: we may not want to die on bad achievements, they're not as bad as bad users
		die "record for achievement $achievementID not found" unless $Achievement;

		# Update fields
		for my $field ($Achievement->NONKEYFIELDS()) {
			my $param = "achievement.${achievementID}.${field}";

			if ($field eq 'assignment_type') {
				my @types = $c->param($param);
				$Achievement->assignment_type(join(',', @types));
			} else {

				if (defined $c->param($param)) {
					$Achievement->$field($c->param($param));
				}
			}
		}

		$db->putAchievement($Achievement);
	}

	$c->{editMode} = 0;

	return (1, $c->maketext('Changes saved.'));
}

# Get list of files that can be imported.
sub getAxpList ($c) {
	return @{ Mojo::File->new($c->ce->{courseDirs}{achievements})->list->grep(qr/.*\.axp/)->map('basename') };
}

1;
