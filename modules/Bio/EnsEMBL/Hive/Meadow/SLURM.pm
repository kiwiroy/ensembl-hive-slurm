=pod 

=head1 NAME

    Bio::EnsEMBL::Hive::Meadow::SLURM

=head1 DESCRIPTION

    This is the 'SLURM' implementation of Meadow

=head1 LICENSE

    Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
    Copyright [2016-2017] EMBL-European Bioinformatics Institute
    Copyright [2017] Genentech, Inc.
    Copyright [2018] Genentech, Inc.

    Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

         http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software distributed under the License
    is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and limitations under the License.

=head1 CONTACT

    For this module only (SLURM.pm)
    - Petr Votava, votava.petr@gene.com
    
    For other Hive questions:
    Please subscribe to the Hive mailing list:  http://listserver.ebi.ac.uk/mailman/listinfo/ehive-users  to discuss Hive-related questions or to be notified of our updates

=cut


package Bio::EnsEMBL::Hive::Meadow::SLURM;

use strict;
use warnings;
use Time::Piece;
use Time::Seconds; 
use File::Temp qw(tempdir); 
use Bio::EnsEMBL::Hive::Utils ('split_for_bash');
use Time::Local ; 

use base ('Bio::EnsEMBL::Hive::Meadow');


our $VERSION = '3.0';       # Semantic version of the Meadow interface:
                            #   change the Major version whenever an incompatible change is introduced,
                            #   change the Minor version whenever the interface is extended, but compatibility is retained.


sub name {  # also called to check for availability; assume Slurm is available if Slurm cluster_name can be established
    my $cmd = "sacctmgr -n -p show clusters 2>/dev/null";

    if(my $name = `$cmd`) {
        $name=~/^(.*?)\|.*/;
        return $1;
    }
}


sub get_current_worker_process_id
{
    my ($self) = @_;

    my $slurm_jobid           = $ENV{'SLURM_JOBID'};
    my $slurm_array_job_id    = $ENV{'SLURM_ARRAY_JOB_ID'};
    my $slurm_array_task_id   = $ENV{'SLURM_ARRAY_TASK_ID'};

    #We have a slurm job
    if(defined($slurm_jobid))
    {
        #We have an array job
        if(defined($slurm_array_job_id) and defined($slurm_array_task_id))
        {
            return "$slurm_array_job_id\_$slurm_array_task_id";
        }
        else
        {
            return $slurm_jobid;
        }
    }
    else
    {
        die "Could not establish the process_id";
    }
}


sub count_pending_workers_by_rc_name {
    my ($self) = @_;
    
    #Needed becasue by default slurm reports all jobs
    my $username = getpwuid($<);
    
    my $jnp = $self->job_name_prefix();
    
    #Prefix for job is not implemented in Slurm, so need to get all
    #and parse it out
    my $cmd = "squeue --array -h -u ${username} -t PENDING -o '%j' 2>/dev/null";

    my %pending_this_meadow_by_rc_name = ();
    my $total_pending_this_meadow = 0;

    foreach my $line (qx/$cmd/)
    {
        if($line=~/\b\Q$jnp\E(\S+)\-\d+(\[\d+\])?\b/)
        {
            $pending_this_meadow_by_rc_name{$1}++;
            $total_pending_this_meadow++;
        }
    }

    return (\%pending_this_meadow_by_rc_name, $total_pending_this_meadow);
}


sub count_running_workers {
    my $self                        = shift @_;
    my $meadow_users_of_interest    = shift @_ || [ 'all' ];

    my $jnp = $self->job_name_prefix();

    my $total_running_worker_count = 0;

    foreach my $meadow_user (@$meadow_users_of_interest)
    {
        my $cmd = "squeue --array -h -u $meadow_user -t RUNNING -o '%j' 2>/dev/null | grep ^$jnp | wc -l";

        my $meadow_user_worker_count = qx/$cmd/;
        $meadow_user_worker_count=~s/\s+//g;       # remove both leading and trailing spaces

        $total_running_worker_count += $meadow_user_worker_count;
    }

    return $total_running_worker_count;
}


sub status_of_all_our_workers { # returns a hashref
    my $self                        = shift @_;
    my $meadow_users_of_interest    = shift @_ || [ 'all' ];

    my $jnp = $self->job_name_prefix();

    my %status_hash = ();

    foreach my $meadow_user (@$meadow_users_of_interest)
    {
        #PENDING, RUNNING, SUSPENDED, CANCELLED, COMPLETING, COMPLETED, CONFIGURING, FAILED, TIMEOUT, PREEMPTED, NODE_FAIL, REVOKED and SPECIAL_EXIT
        my $cmd = "squeue --array -h -u $meadow_user -o '%i|%T' 2>/dev/null";

        foreach my $line (`$cmd`) {
            my ($worker_pid, $status) = split(/\|/, $line);

            # TODO: not exactly sure what these are used for in the external code - this is based on the LSF status codes that were ignored
            next if( ($status eq 'COMPLETED') or ($status eq 'FAILED'));

            $status_hash{$worker_pid} = $status;
        }
    }

    return \%status_hash;
}


sub check_worker_is_alive_and_mine {
    my ($self, $worker) = @_;

    my $wpid = $worker->process_id();
    my $this_user = $ENV{'USER'};
    my $cmd = "squeue -h -u $this_user --job=$wpid 2>&1 | grep -v 'Invalid job id specified' | grep -v 'Invalid user'";

    my $is_alive_and_mine = qx/$cmd/;
    $is_alive_and_mine =~ s/^\s+|\s+$//g;
    
    return $is_alive_and_mine;
}


sub kill_worker {
    my ($self, $worker, $fast) = @_;

    # -r option is not available in Slurm directly in scancel
    system('scancel', $worker->process_id());
}


sub _convert_to_datetime {      # a private subroutine that can recover missing year from an incomplete date and then transforms it into SQL's datetime for storage
    my ($weekday, $yearless, $real_year) = @_;

    if($real_year) {
        my $datetime = Time::Piece->strptime("$yearless $real_year", '%b %d %T %Y');
        return $datetime->date.' '.$datetime->hms;
    } else {
        my $curr_year = Time::Piece->new->year();

        my $years_back = 0;
        while ($years_back < 28) {  # The Gregorian calendar repeats every 28 years
            my $candidate_year = $curr_year - $years_back;
            my $datetime = Time::Piece->strptime("$yearless $candidate_year", '%b %d %T %Y');
            if($datetime->wdayname eq $weekday) {
                return $datetime->date.' '.$datetime->hms;
            }
            $years_back++;
        }
    }

    return; # could not guess the year
}


# Works with Slurm 17.02.9 

sub parse_report_source_line {
    my ($self, $bacct_source_line) = @_;

    warn "$bacct_source_line\n"; 
    

    warn "SLURM::parse_report_source_line( \"$bacct_source_line\" )\n";
   
    
    my %units_2_megs = (
        'K' => 1.0/1024,
        'M' => 1,
        'G' => 1024,
        'T' => 1024*1024,
    );
    
   # local $/ = "------------------------------------------------------------------------------\n\n";
    open(my $bacct_fh, $bacct_source_line) || die "Cant open $bacct_source_line\n"; 
    my $record = <$bacct_fh>; # skip the header
    $record = <$bacct_fh>; # skip the header
    
    my %report_entry = ();
   
    for my $record (<$bacct_fh>) {
        chomp $record;

        my @lines = split(/\|/, $record);     

        my $job_name   = $lines[0];   # JobName - for explanation please look at sacct command 
        my $job_id     = $lines[1];   # JobID 
        my $exit_code  = $lines[2];   # ExitCode 
        my $mem_used   = $lines[3];   # MaxRSS 
        my $reserved_time = $lines[4];   # Reserved / pending time ... 
        my $max_disk_read = $lines[5];   # MaxDiskRead 
        my $total_cpu     = $lines[6];   # CPUTimeRAW
        my $elapsed       = $lines[7];   # ElapsedRAW 
        my $state         = $lines[8];   # State 
        my $exception_status = $lines[9];   # DerivedExitCode  

         $job_id =~ s/\.batch//; 

        next unless $job_name =~ m/batch/; 

        $mem_used =~ s/K$//; 
        $mem_used /= 1024; # convert to kb to meg 

     
        my $cause_of_death = get_cause_of_death($state) ; 
        $exception_status  = $cause_of_death ; 
    
          $report_entry{ $job_id } = {
             # entries for 'worker' table:
                'when_died'         => undef, 
                'cause_of_death'    => $cause_of_death, 

                 # entries for 'worker_resource_usage' table:
                 'exit_status'       => $exit_code, 
                 'exception_status'  => $exception_status,
                 'mem_megs'          => $mem_used, # mem_in_units  * $units_2_megs{$mem_unit},
                 'swap_megs'         => $max_disk_read, # swap_in_units * $units_2_megs{$swap_unit},
                 'pending_sec'       => $reserved_time, 
                 'cpu_sec'           => $total_cpu ,
                 'lifespan_sec'      => $elapsed , 
            };
    } 

    close $bacct_fh;
    my $exit = $? >> 8;
    die "Could not read from '$bacct_source_line'. Received the error $exit\n" if $exit;
    
    return \%report_entry;
}

    
sub get_cause_of_death { 
   my ($state) = @_;   

    my $cod = "UNKNOWN"; 
    my %status_2_cod = (
       'TERM_MEMLIMIT'     => 'MEMLIMIT',
       'TERM_RUNLIMIT'     => 'RUNLIMIT',
       'CANCELLED'          => 'KILLED_BY_USER',    # bkill     (wait until it dies)
       'TERM_FORCE_OWNER'  => 'KILLED_BY_USER',    # bkill -r  (quick remove)
    ); 
    if ( $state =~ m/CANCELLED/ ) {  
       $cod = "KILLED_BY_USER"; 
    }  
    return $cod; 
}

sub get_report_entries_for_process_ids {
    my $self = shift @_;    # make sure we get if off the way before splicing

    die("aaaarg"); 
    my %combined_report_entries = ();

    while (my $pid_batch = join(',', map { "'$_'" } splice(@_, 0, 20))) {  # can't fit too many pids on one shell cmdline 

        # sacct -j 19661,19662,19663
        my $cmd = "sacct -p --format JobName,JobID,ExitCode,MaxRSS,Reserved,MaxDiskRead,CPUTimeRAW,ElapsedRAW,State,DerivedExitCode -j $pid_batch  |" ;

        warn "SLURM::get_report_entries_for_process_ids() running cmd:\n\t$cmd\n";
        my $batch_of_report_entries = $self->parse_report_source_line( $cmd );

        %combined_report_entries = (%combined_report_entries, %$batch_of_report_entries);
    }

    return \%combined_report_entries;
}



# Gets called from load_resource_usage.pl 

sub get_report_entries_for_time_interval {
    my ($self, $from_time, $to_time, $username) = @_;

    my $from_timepiece = Time::Piece->strptime($from_time, '%Y-%m-%d %H:%M:%S');
    $from_time = $from_timepiece->strftime('%Y-%m-%dT%H:%M');

    my $to_timepiece = Time::Piece->strptime($to_time, '%Y-%m-%d %H:%M:%S') + 2*ONE_MINUTE;
    $to_time = $to_timepiece->strftime('%Y-%m-%dT%H:%M');

    # sacct -s CA,CD,CG,F -S 2018-02-27T16:48 -E 2018-02-27T16:50
    my $cmd = "sacct -p -s CA,CD,CG,F  --format JobName,JobID,ExitCode,MaxRSS,Reserved,MaxDiskRead,CPUTimeRAW,ElapsedRAW,State,DerivedExitCode     -S $from_time -E $to_time ".($username ? "-u $username" : '') . ' |';

    warn "SLURM::get_report_entries_for_time_interval() running cmd:\n\t$cmd\n";

    my $batch_of_report_entries = $self->parse_report_source_line( $cmd );

    return $batch_of_report_entries;
}


sub submit_workers {
    my ($self, $worker_cmd, $required_worker_count, $iteration, $rc_name, $rc_specific_submission_cmd_args, $submit_log_subdir) = @_;

    my $job_array_common_name               = $self->job_array_common_name($rc_name, $iteration);
    my $job_array_spec                      = "1-${required_worker_count}";
    my $meadow_specific_submission_cmd_args = $self->config_get('SubmissionOptions');

    my ($submit_stdout_file, $submit_stderr_file);

    if($submit_log_subdir) {
        $submit_stdout_file = $submit_log_subdir . "/log_${rc_name}_%A_%a.out";
        $submit_stderr_file = $submit_log_subdir . "/log_${rc_name}_%A_%a.err";
    } else {
        $submit_stdout_file = '/dev/null';
        $submit_stderr_file = '/dev/null';
    }

    #No equivalent in sbatch, but can be accomplished with stdbuf -oL -eL
    #$ENV{'LSB_STDOUT_DIRECT'} = 'y';  # unbuffer the output of the bsub command
    
    #Note: job arrays share the same name in slurm and are 0-based, but this may still work
    my @cmd = ('sbatch',
        '-o', $submit_stdout_file,
        '-e', $submit_stderr_file,
        '-a', $job_array_spec,
        '-J', $job_array_common_name, 
        split_for_bash($rc_specific_submission_cmd_args),
        split_for_bash($meadow_specific_submission_cmd_args),
        $worker_cmd,
    );
 
    print "Executing [ ".$self->signature." ] \t\t".join(' ', @cmd)."\n";  

    # Hack for sbatchd 
    my $tmp = File::Temp->new(  TEMPLATE => "ehive.$$.XXXX", UNLINK => 0, SUFFIX => '.sh', DIR => tempdir() );
    print $tmp join(" ", @cmd);
 
    print "Written file $tmp\n"; 
    system ("sh $tmp") && die "Could not submit job(s): $!, $?";  # let's abort the beekeeper and let the user check the syntax  
    #system( @cmd ) && die "Could not submit job(s): $!, $?";  # let's abort the beekeeper and let the user check the syntax  
}

1;
