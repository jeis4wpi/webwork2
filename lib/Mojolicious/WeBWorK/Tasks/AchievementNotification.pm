package Mojolicious::WeBWorK::Tasks::AchievementNotification;
use Mojo::Base 'Minion::Job', -signatures;

use Email::Stuffer;
use Email::Sender::Transport::SMTP;
use Mojo::Template;
use Mojo::File;

use WeBWorK::Debug qw(debug);
use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Localize;
use WeBWorK::Utils qw(createEmailSenderTransportSMTP);
use WeBWorK::WWSafe;
use WeBWorK::SafeTemplate;

# send student notification that they have earned an achievement
sub run ($job, $mail_data) {
	my $courseID = $job->info->{notes}{courseID};

	my $ce = eval { WeBWorK::CourseEnvironment->new({ courseName => $courseID }); };
	return $job->fail("Could not construct course environment for $courseID.")
		unless $ce;

	$job->{language_handle} = WeBWorK::Localize::getLoc($ce->{language} || 'en');

	my $db = WeBWorK::DB->new($ce);
	return $job->fail($job->maketext('Could not obtain database connection for [_1].', $courseID))
		unless $db;

	return $job->fail($job->maketext('Cannot notify student without an achievement.'))
		unless $mail_data->{achievementID};
	$mail_data->{achievement} = $db->getAchievement($mail_data->{achievementID});
	return $job->fail($job->maketext('Could not find achievement [_1].', $mail_data->{achievementID}))
		unless $mail_data->{achievement};

	my $result_message = eval { $job->send_achievement_notification($ce, $db, $mail_data) };
	if ($@) {
		$job->app->log->error("An error occurred while trying to send email: $@");
		return $job->fail($job->maketext('An error occurred while trying to send email: [_1]', $@));
	}
	$job->app->log->info("Message sent to $mail_data->{recipient}");
	return $job->finish($result_message);
}

sub send_achievement_notification ($job, $ce, $db, $mail_data) {
	my $from = $ce->{mail}{achievementEmailFrom};
	die 'Cannot send achievement email notification without mail{achievementEmailFrom}.' unless $from;

	my $user_record = $db->getUser($mail_data->{recipient});
	die "Record for user $mail_data->{recipient} not found\n" unless ($user_record);
	die "User $mail_data->{recipient} does not have an email address -- skipping\n"
		unless ($user_record->email_address =~ /\S/);

	my $compartment = WeBWorK::WWSafe->new;
	$compartment->share_from('main',
		[qw(%Encode:: %Mojo::Base:: %Mojo::Exception:: %Mojo::Template:: %WeBWorK::SafeTemplate::)]);

	# Since the WeBWorK::SafeTemplate module cannot add "no warnings 'ambiguous'", those warnings must be prevented
	# with the following $SIG{__WARN__} handler.
	local $SIG{__WARN__} = sub {
		my $warning = shift;
		return if $warning =~ /Warning: Use of "scalar" without parentheses is ambiguous/;
		warn $warning;
	};

	our $template_vars = {
		ce              => $ce,
		user            => $user_record,
		user_status     => $ce->status_abbrev_to_name($user_record->status),
		achievement     => $mail_data->{achievement},
		setID           => $mail_data->{set_id},
		nextLevelPoints => $mail_data->{nextLevelPoints},
		pointsEarned    => $mail_data->{pointsEarned}
	};

	our $template =
		Mojo::File->new("$ce->{courseDirs}{achievement_notifications}/$mail_data->{achievement}{email_template}")
		->slurp;
	$compartment->share(qw($template $template_vars));

	my $body = $compartment->reval(
		'my $renderer = WeBWorK::SafeTemplate->new(vars => 1); $renderer->render($template, $template_vars);', 1);

	die $@ if $@;

	my $email =
		Email::Stuffer->to($user_record->email_address)->from($from)->subject($mail_data->{subject})->text_body($body)
		->header('X-Remote-Host' => $mail_data->{remote_host});

	$email->send_or_die({
		transport => createEmailSenderTransportSMTP($ce),
		$ce->{mail}{set_return_path} ? (from => $ce->{mail}{set_return_path}) : ()
	});
	debug 'email sent successfully to ' . $user_record->email_address;

	return $job->maketext('Message sent to [_1] at [_2].', $mail_data->{recipient}, $user_record->email_address) . "\n";
}

sub maketext ($job, @args) {
	return &{ $job->{language_handle} }(@args);
}

1;
