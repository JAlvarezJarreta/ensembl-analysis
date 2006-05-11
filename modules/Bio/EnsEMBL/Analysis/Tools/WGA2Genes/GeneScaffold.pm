
=head1 NAME

Bio::EnsEMBL::Analysis::Tools::WGA2Genes::GeneScaffold 

=head1 SYNOPSIS

A Bio::EnsEMBL::Slice that is comprised
of pieces of different target sequences, inferred by an alignment
of the target to a finished, query genome sequence. This object
extends Slice with mappings to/from the query and target

Assumptions:

- that the given GenomicAlignBlocks are sorted with respect
  to the reference and non-overlapping on query and target

- that the given list of features is sorted with respect to
  the reference

=cut


package Bio::EnsEMBL::Analysis::Tools::WGA2Genes::GeneScaffold;

use strict;
use vars qw(@ISA);

use Bio::EnsEMBL::Utils::Argument qw(rearrange);
use Bio::EnsEMBL::Utils::Sequence qw(reverse_comp);

use Bio::EnsEMBL::Slice;

use Bio::EnsEMBL::Analysis::Tools::WGA2Genes::CoordUtils;

@ISA = qw(Bio::EnsEMBL::Slice);

my $FROM_CS_NAME = 'chromosome';
my $TO_CS_NAME   = 'scaffold';
my $GENE_SCAFFOLD_CS_NAME  = 'genescaffold';

my $INTERPIECE_PADDING      = 100;
my $MAX_READTHROUGH_DIST    = 15;
my $NEAR_CONTIG_END         = 15;
###############################################

sub new {
  my ($caller, %given_args) = @_;

  my $class = ref($caller) || $caller;

  my ($name,
      $genomic_align_blocks,
      $transcripts,
      $from_slice,
      $to_slices,
      $exnted_into_gaps,
      $add_gaps,
      ) = rearrange([qw(NAME
                        GENOMIC_ALIGN_BLOCKS
                        TRANSCRIPTS
                        FROM_SLICE
                        TO_SLICES
                        EXTEND_INTO_GAPS
                        ADD_GAPS)], %given_args);

  $name = "GeneScaffold" if not defined $name;
  $add_gaps = 1 if not defined $add_gaps;
  $extend_into_gaps = 1 if not defined $extend_into_gaps;

  my $aln_map = _make_alignment_mapper($genomic_align_blocks);

  my ($gs_seq, $from_mapper, $to_mapper) = 
      _construct_sequence($genomic_align_blocks,
                          $aln_map,
                          $transcripts,
                          $from_slice,
                          $to_slices,
                          $extend_into_gaps,
                          $add_gaps);

  return undef if not defined $from_mapper;

  my $self = $class->SUPER::new(-coord_system => 
                                  Bio::EnsEMBL::CoordSystem->new(-name => $GENE_SCAFFOLD_CS_NAME,
                                                                 -rank => 1),
                                -seq_region_name => $name,
                                -seq => $gs_seq,
                                -start => 1,
                                -end   => length($gs_seq),
                                );

  $self->from_slice($from_slice);
  $self->to_slices($to_slices);
  $self->alignment_mapper($aln_map);
  $self->from_mapper($from_mapper);
  $self->to_mapper($to_mapper);

  return $self;
}


###################################################################
# FUNCTION   : place_transcript
#
# Description:
#    Takes a transcript, and uses the mapping between 
#    query coords and gene scaffold coords to produces a transcript 
#    that is the result of "projecting" the original transcript, 
#    through alignment, onto the gene scaffold. 
###################################################################

sub place_transcript {
  my ($self, 
      $tran) = @_;

  my (@all_coords, @new_exons);

  my @orig_exons = @{$tran->get_all_translateable_Exons};
  if ($tran->strand < 0) {
    @orig_exons = reverse @orig_exons;
  }

  my $source_tran_length = 0;
  map { $source_tran_length += $_->length } @orig_exons; 

  foreach my $orig_exon (@orig_exons) {
    my @crds = $self->from_mapper->map_coordinates($orig_exon->slice->seq_region_name,
                                                   $orig_exon->start,
                                                   $orig_exon->end,
                                                   1,
                                                   $FROM_CS_NAME);
    push @all_coords, @crds;
  }

  my $start_not_found = 0;
  my $end_not_found   = 0;

  # Replace coords at start and end that map down to gaps with gaps.
  # Although we have already trimmed back the gene scaffold for gap 
  # exons at the ends, individual transripts could begin/end anywhere
  # in the gene scaffold. 

  for(my $i=0; $i < @all_coords; $i++) {

    if ($all_coords[$i]->isa("Bio::EnsEMBL::Mapper::Coordinate")) {
      my ($tcoord) = $self->to_mapper->map_coordinates($GENE_SCAFFOLD_CS_NAME,
                                                       $all_coords[$i]->start,
                                                       $all_coords[$i]->end,
                                                       1,
                                                       $GENE_SCAFFOLD_CS_NAME);
      if ($tcoord->isa("Bio::EnsEMBL::Mapper::Coordinate")) {
        last;
      } else {
        $all_coords[$i] = 
            Bio::EnsEMBL::Mapper::Gap->new(1, $tcoord->length);
        $start_not_found = 1;
      }
    } else {
      $start_not_found = 1;
    }
  }
  for(my $i=scalar(@all_coords)-1; $i >= 0; $i--) {
    if ($all_coords[$i]->isa("Bio::EnsEMBL::Mapper::Coordinate")) {
      my ($tcoord) = $self->to_mapper->map_coordinates($GENE_SCAFFOLD_CS_NAME,
                                                       $all_coords[$i]->start,
                                                       $all_coords[$i]->end,
                                                       1,
                                                       $GENE_SCAFFOLD_CS_NAME);
      if ($tcoord->isa("Bio::EnsEMBL::Mapper::Coordinate")) {
        last;
      } else {
        $all_coords[$i] = 
            Bio::EnsEMBL::Mapper::Gap->new(1, $tcoord->length);
        $end_not_found = 1;
      }
    } else {
      $end_not_found = 1;
    }
  }

  my $need_another_pass;
  do {
    $need_another_pass = 0;

    my (@proc_coords, @gap_indices);
    # merge gaps
    foreach my $c (@all_coords) {
      if ($c->isa("Bio::EnsEMBL::Mapper::Gap")) {
        if (@proc_coords and 
            $proc_coords[-1]->isa("Bio::EnsEMBL::Mapper::Gap")) {
          $proc_coords[-1]->end( $proc_coords[-1]->end + $c->length );
        } else {
          push @proc_coords, Bio::EnsEMBL::Mapper::Gap->new(1, 
                                                            $c->length);
          push @gap_indices, scalar(@proc_coords) - 1;
        }
      } else {
        push @proc_coords, $c;
      }
    }

    GAP: foreach my $idx (@gap_indices) {
      my $gap = $proc_coords[$idx];
      my $frameshift = $gap->length % 3;

      if ($frameshift) {
        my $bases_to_remove = 3 - $frameshift;      

        # calculate "surplus" bases on incomplete codons to left and right
        my ($left_surplus, $right_surplus) = (0,0);
        for(my $j=$idx-1; $j >= 0; $j--) {
          $left_surplus += $proc_coords[$j]->length;
        }
        for(my $j=$idx+1; $j < @proc_coords; $j++) {
          $right_surplus += $proc_coords[$j]->length;
        }
        
        $left_surplus  = $left_surplus % 3;
        $right_surplus = $right_surplus % 3;

        if ($left_surplus) {
          # eat left
          $bases_to_remove = $left_surplus;
          
          my $left_coord = $proc_coords[$idx - 1];
          if ($left_coord->length > $bases_to_remove) {
            $gap->end($gap->end + $bases_to_remove);
            $left_coord->end( $left_coord->end - $bases_to_remove );
          } else {
            # we need to eat away the whole of this coord
            $proc_coords[$idx-1] = 
                Bio::EnsEMBL::Mapper::Gap->new(1,$left_coord->length);
          }
        }
        if ($right_surplus) {
          $bases_to_remove = $right_surplus;

          my $right_coord = $proc_coords[$idx + 1];
          if ($right_coord->length > $bases_to_remove) {
            $gap->end($gap->end + $bases_to_remove);
            $right_coord->start( $right_coord->start + $bases_to_remove);
          } else {
            # we need to eat away the whole of this coord
            $proc_coords[$idx+1] = 
                Bio::EnsEMBL::Mapper::Gap->new(1,$right_coord->length);
          }
        }
        
        $need_another_pass = 1;
        last GAP;
      }      
    }
    @all_coords = @proc_coords;    
  } while ($need_another_pass);


  foreach my $coord (@all_coords) {
    if ($coord->isa("Bio::EnsEMBL::Mapper::Coordinate")) {
      push @new_exons, Bio::EnsEMBL::Exon->new(-start => $coord->start,
                                               -end   => $coord->end,
                                               -strand => $tran->strand,
                                               -slice => $self);
    }
  }

  my $total_tran_bps = 0;
  map { $total_tran_bps += $_->length } @new_exons; 

  if (not @new_exons) {
    # the whole transcript mapped to gaps
    return 0;
  }

  #
  # sort exons into rank order 
  #
  if ($tran->strand < 0) {
    @new_exons = sort { $b->start <=> $a->start } @new_exons;
  } else {
    @new_exons = sort { $a->start <=> $b->start } @new_exons;
  }

  #
  # calculate phases, and add supporting features
  #
  my ($previous_exon);
  foreach my $exon (@new_exons) {

    if (defined $previous_exon) {
      $exon->phase($previous_exon->end_phase);
    } else {
      $exon->phase(0);
    }

    $exon->end_phase((($exon->end - $exon->start + 1) + $exon->phase)%3);

    # need to map back to the genomic coords to get the supporting feature
    # for this exon;
    my $extent_start = $exon->start;
    my $extent_end   = $exon->end;
    if ($exon->strand > 0) {
      $extent_start += 3 - $exon->phase if $exon->phase;
      $extent_end   -= $exon->end_phase if $exon->end_phase;
    } else {
      $extent_start += $exon->end_phase if $exon->end_phase;
      $extent_end   -=  3 - $exon->phase if $exon->phase;
    }

    if ($extent_end > $extent_start) {
      # if not, we've eaten away the whole exon, so there is no support

      my @gen_coords = $self->from_mapper->map_coordinates($GENE_SCAFFOLD_CS_NAME,
                                                           $extent_start,
                                                           $extent_end,
                                                           1,
                                                           $GENE_SCAFFOLD_CS_NAME);

      my @fps;
      my $cur_gs_start = $extent_start;
      foreach my $g_coord (@gen_coords) {
        my $cur_gs_end = $cur_gs_start + $g_coord->length - 1;
                
        if ($g_coord->isa("Bio::EnsEMBL::Mapper::Coordinate")) {

          my ($p_coord) = $tran->genomic2pep($g_coord->start, 
                                             $g_coord->end,
                                             $exon->strand);
          
          my $fp = Bio::EnsEMBL::FeaturePair->
              new(-seqname  => $self->seq_region_name,
                  -start    => $cur_gs_start,
                  -end      => $cur_gs_end,
                  -strand   => $exon->strand,
                  -score    => 100.0,
                  -hseqname => $tran->translation->stable_id,
                  -hstart   => $p_coord->start,
                  -hend     => $p_coord->end,
                  -hstrand => $p_coord->strand);
          push @fps, $fp;
        }
        
        $cur_gs_start += $g_coord->length;
      }
        
      if (@fps) {
        my $f = Bio::EnsEMBL::DnaPepAlignFeature->new(-features => \@fps);
        $exon->add_supporting_features($f);
      }
    }

    $previous_exon = $exon;
  }

  #
  # merge abutting exons; deals with exon fusion events, and 
  # small, frame-preserving insertions in the target
  #
  my @merged_exons;
  foreach my $exon (@new_exons) {
    if (@merged_exons) {

      my $prev_exon = pop @merged_exons;
   
      my ($new_start, $new_end);

      if ($tran->strand < 0) {
        my $intron_len = $prev_exon->start - $exon->end - 1;
        if ($intron_len % 3 == 0 and 
            $intron_len <= $MAX_READTHROUGH_DIST) { 
          $new_start = $exon->start;
          $new_end   = $prev_exon->end;
        }
      } else {
        my $intron_len = $exon->start - $prev_exon->end - 1;
        if ($intron_len % 3 == 0 and 
            $intron_len <= $MAX_READTHROUGH_DIST) {
          $new_start = $prev_exon->start;
          $new_end   = $exon->end;
        }
      }

      if (defined $new_start and defined $new_end) {
        my $merged_exon = Bio::EnsEMBL::Exon->
            new(-start => $new_start,
                -end   => $new_end,
                -strand => $tran->strand,
                -phase => $prev_exon->phase,
                -end_phase => $exon->end_phase,
                -slice  => $exon->slice);
        
        my @ug_feats;
        if (@{$prev_exon->get_all_supporting_features}) {
          my ($sf) = @{$prev_exon->get_all_supporting_features};
          push @ug_feats, $sf->ungapped_features;
        }
        if (@{$exon->get_all_supporting_features}) {
          my ($sf) = @{$exon->get_all_supporting_features};
          push @ug_feats, $sf->ungapped_features;
        }
        if (@ug_feats) {
          my $new_sup_feat = Bio::EnsEMBL::DnaPepAlignFeature->
              new(-features => \@ug_feats);
          $merged_exon->add_supporting_features($new_sup_feat);
        }

        push @merged_exons, $merged_exon;
        next;
      } else {
        push @merged_exons, $prev_exon;
        push @merged_exons, $exon;
      }      
    } else {
      push @merged_exons, $exon;
    }
  }
  

  my $proj_tran = Bio::EnsEMBL::Transcript->new();

  my (@trans_fps);
  foreach my $exon (@merged_exons) {
    $proj_tran->add_Exon($exon);
    
    if (@{$exon->get_all_supporting_features}) {
      my ($sf) = @{$exon->get_all_supporting_features};
      my @e_fps = $sf->ungapped_features;
      push @trans_fps, @e_fps;
    }
  }

  #
  # do transcript-level supporting features/attributes
  #
  my $t_sf = Bio::EnsEMBL::DnaPepAlignFeature->
      new(-features => \@trans_fps);
  $t_sf->hcoverage( 100 * ($total_tran_bps / $source_tran_length) );
  $proj_tran->add_supporting_features($t_sf);

  #
  # set translation
  #
  my $translation = Bio::EnsEMBL::Translation->new();
  $translation->start_Exon($merged_exons[0]);
  $translation->start(1);
  $translation->end_Exon($merged_exons[-1]);
  $translation->end($merged_exons[-1]->end - $merged_exons[-1]->start + 1);

  $proj_tran->translation($translation);

  my $pep = $proj_tran->translate;

  if (not defined $pep) {
    # this can happen if the transcript comprises a single stop codon only
    return 0;
  }
  
  my $prop_non_gap = 100 - (100 * (($pep->seq =~ tr/X/X/) / $pep->length));
  my $num_stops = $pep->seq =~ tr/\*/\*/;
  
  #
  # finally, attributes
  #
  my @attributes;


  my $cov_attr = Bio::EnsEMBL::Attribute->
      new(-code => 'HitCoverage',
          -name => 'hit coverage',
          -description => 'coverage of parent transcripts',
          -value => sprintf("%.1f",
                            100 * ($total_tran_bps / $source_tran_length)));
  push @attributes, $cov_attr;
  
  my $gap_attr = Bio::EnsEMBL::Attribute->
      new(-code => 'PropNonGap',
          -name => 'proportion non gap',
          -description => 'proportion non gap',
          -value => sprintf("%.1f", 
                            $prop_non_gap));
  push @attributes, $gap_attr;
  
  if ($start_not_found and $tran->strand > 0 or
      $end_not_found and $tran->strand < 0) {
    my $attr = Bio::EnsEMBL::Attribute->
        new(-code => 'StartNotFound',
            -name => 'start not found',
            -description => 'start not found',
            -value => 1);
    push @attributes, $attr;
  }
  if ($end_not_found and $tran->strand > 0 or
      $start_not_found and $tran->strand < 0) {
    my $attr = Bio::EnsEMBL::Attribute->
        new(-code => 'EndNotFound',
            -name => 'end not found',
            -description => 'end not found',
            -value => 1);
    push @attributes, $attr;
  }


  my $stop_attr = Bio::EnsEMBL::Attribute->
      new(-code => 'NumStops',
          -name => 'number of stops',
          -desc => 'Number of stops before editing',
          -value => $num_stops);
  push @attributes, $stop_attr;

  # indentify gap exons
  my $gap_exons = 0;
  foreach my $e (@{$proj_tran->get_all_Exons}) {
    my ($coord) = $self->to_mapper->map_coordinates($GENE_SCAFFOLD_CS_NAME,
                                                    $e->start,
                                                    $e->end,
                                                    1,
                                                    $GENE_SCAFFOLD_CS_NAME);
    if ($coord->isa("Bio::EnsEMBL::Mapper::Gap")) {
      $gap_exons++;
    }
  }
  my $gap_exon_attr = Bio::EnsEMBL::Attribute->
      new(-code => 'GapExons',
          -name => 'gap exons',
          -description => 'number of gap exons',
          -value => $gap_exons);
  push @attributes, $gap_exon_attr;

  my $tranid_attr = Bio::EnsEMBL::Attribute->
      new(-code => 'SourceTran',
          -name => 'source transcript',
          -description => 'source transcript',
          -value => $tran->stable_id);
  push @attributes, $tranid_attr;

  $proj_tran->add_Attributes(@attributes);

  return $proj_tran;
}


sub stringify_alignment {
  my ($self) = @_;

  my @coords = $self->alignment_mapper->map_coordinates($self->from_slice->seq_region_name,
                                                        $self->from_slice->start,
                                                        $self->from_slice->end,
                                                        1,
                                                        $FROM_CS_NAME);
  my $string = "";
  my $position = $self->from_slice->start;
  foreach my $c (@coords) {
    my $ref_start = $position;
    my $ref_end = $position + $c->length - 1;
    $position += $c->length;
    
    $string .= sprintf("%s %d %d ", $self->from_slice->seq_region_name, $ref_start, $ref_end);

    if ($c->isa("Bio::EnsEMBL::Mapper::Gap")) {
      $string .= "[GAP]\n";
    } else {
      $string .= "[%s %d %d %s]\n", $c->id, $c->start, $c->end, $c->strand;
    }
  }

  return $string;
}

sub project_up {
  my ($self) = @_;

  my $tlsl = $self->from_slice;

  my @comps = $self->from_mapper->map_coordinates($GENE_SCAFFOLD_CS_NAME,
                                                  1,
                                                  $self->length,
                                                  1,
                                                  $GENE_SCAFFOLD_CS_NAME);
                                                  
  my @segments;
  
  my $current_pos = 1;
  foreach my $c (@comps) {
    my $start = $current_pos;
    my $end   = $current_pos + $c->length - 1;
    $current_pos += $c->length;
    
    if ($c->isa("Bio::EnsEMBL::Mapper::Coordinate")) {
      
      my $slice = $tlsl->adaptor->fetch_by_region($tlsl->coord_system->name,
                                                  $tlsl->seq_region_name,
                                                  $c->start,
                                                  $c->end,
                                                  1);
      
      push @segments, bless([$start, $end, $slice],
                            "Bio::EnsEMBL::ProjectionSegment");
    }
  }

  return @segments;
}

sub project_down {
  my ($self) = @_;

  my @comps = $self->to_mapper->map_coordinates($GENE_SCAFFOLD_CS_NAME,
                                                1,
                                                $self->length,
                                                1,
                                                $GENE_SCAFFOLD_CS_NAME);
                                                  
  my @segments;
  
  my $current_pos = 1;
  foreach my $c (@comps) {
    my $start = $current_pos;
    my $end   = $current_pos + $c->length - 1;
    $current_pos += $c->length;
    
    if ($c->isa("Bio::EnsEMBL::Mapper::Coordinate")) {
      my $tlsl = $self->to_slices->{$c->id};
      
      my $slice = $tlsl->adaptor->fetch_by_region($tlsl->coord_system->name,
                                                  $tlsl->seq_region_name,
                                                  $c->start,
                                                  $c->end,
                                                  $c->strand);
      
      push @segments, bless([$start, $end, $slice],
                            "Bio::EnsEMBL::ProjectionSegment");
    }
  }

  return @segments;
}


###############################################
# Internal helper methods
###############################################


#################################################

sub _construct_sequence {
  my ($gen_al_blocks,
      $map,
      $transcripts,
      $from_slice,
      $to_slices,
      $extend_into_gaps,
      $add_gaps) = @_;

  # Basic gene-scaffold structure is taken directly from the given block list
  my @block_coord_pairs;
  foreach my $bl (@{$gen_al_blocks}) {
    my $qy_al = $bl->reference_genomic_align;
    my ($tg_al) = @{$bl->get_all_non_reference_genomic_aligns};

    my $from_coord = Bio::EnsEMBL::Mapper::Coordinate->new($qy_al->dnafrag->name,
                                                           $qy_al->dnafrag_start,
                                                           $qy_al->dnafrag_end,
                                                           1);
    my $to_coord   = Bio::EnsEMBL::Mapper::Coordinate->new($tg_al->dnafrag->name,
                                                           $tg_al->dnafrag_start,
                                                           $tg_al->dnafrag_end,
                                                           $tg_al->dnafrag_strand);
    my $pair = Bio::EnsEMBL::Mapper::Pair->new($from_coord, 
                                               $to_coord);
    push @block_coord_pairs, $pair;
  }
  @block_coord_pairs = sort { $a->from->start <=> $b->from->start } @block_coord_pairs;

  # we now proceed to amend the structure with inserted gaps

  # step 1: flatten the exons from the transcripts into a non-overlapping
  # list, ommitting terminal exons that map completely to gaps
  my $features = _projectable_features_from_transcripts($map,
                                                        $transcripts);
  
  # step 2: infer list of exon regions that map to gaps. We are only 
  # interested, at this stage, in regions outside the blocks, because
  # these are the ones with potential to be "filled"

  my (@gap_positions, @coord_positions);

  foreach my $f (sort { $a->start <=> $b->start } @$features) {
    my $current_pos = $f->start;
    
    foreach my $c ($map->map_coordinates($f->slice->seq_region_name,
                                         $f->start,
                                         $f->end,
                                         1,
                                         $FROM_CS_NAME)) {
      my $from_coord = Bio::EnsEMBL::Mapper::Coordinate->new($f->slice->seq_region_name,
                                                             $current_pos,
                                                             $current_pos + $c->length - 1,
                                                             1);
      
      
      $current_pos += $c->length;
      
      if ($c->isa("Bio::EnsEMBL::Mapper::Gap")) {
        # only consider gaps that lies outside blocks
        my $overlaps_block = 0;
        foreach my $bl (@block_coord_pairs) {
          if ($bl->from->start <= $from_coord->end and
              $bl->from->end   >= $from_coord->start) {
            $overlaps_block = 1;
            last;
          }

        }
        if (not $overlaps_block) {
          push @gap_positions, Bio::EnsEMBL::Mapper::Pair->new($from_coord,
                                                               $c);
        }
      } else {
        push @coord_positions, Bio::EnsEMBL::Mapper::Pair->new($from_coord,
                                                               $c);
      }
    }    
  }
  
  my @all_coord_pairs = (@block_coord_pairs, @gap_positions);
  @all_coord_pairs = sort { $a->from->start <=> $b->from->start } @all_coord_pairs;

  # Non-fillable gaps:
  # 1. Gaps before the first or after the last block
  # 2. If one of the flanking coords is on the same CDS region
  #    as the gap, and the end of the aligned region does
  #    not align to a sequence-level gap
  # 3. If the 2 flanking coords are consistent and not
  #    separated by a sequence-level gap
  # 

  while(@all_coord_pairs and 
        $all_coord_pairs[0]->to->isa("Bio::EnsEMBL::Mapper::Gap")) {
    shift @all_coord_pairs;
  }
  while(@all_coord_pairs and 
        $all_coord_pairs[-1]->to->isa("Bio::EnsEMBL::Mapper::Gap")) {
    pop @all_coord_pairs;
  }

  if ($extend_into_gaps) {
    my (%pairs_to_remove, @replacements);
    
    for(my $i=0; $i < @all_coord_pairs; $i++) {
      my $this_pair = $all_coord_pairs[$i];
      
      if ($this_pair->to->isa("Bio::EnsEMBL::Mapper::Gap")) {
        # if it's gap that can be filled, leave it. Otherwise, remove it
        my ($left_non_gap, $right_non_gap);
        for(my $j=$i-1; $j>=0; $j--) {
          if ($all_coord_pairs[$j]->to->
              isa("Bio::EnsEMBL::Mapper::Coordinate")) {
            $left_non_gap = $all_coord_pairs[$j];
            last;
          }
        }
        for(my $j=$i+1; $j < @all_coord_pairs; $j++) {
          if ($all_coord_pairs[$j]->to->
              isa("Bio::EnsEMBL::Mapper::Coordinate")) {
            $right_non_gap = $all_coord_pairs[$j];
            last;
          }
        }
        
        
        my ($ex_left, $ex_left_up, $ex_left_down) = 
            extend_coord($left_non_gap->to,
                         $to_slices->{$left_non_gap->to->id});
        my ($ex_right, $ex_right_up, $ex_right_down) = 
            extend_coord($right_non_gap->to,
                         $to_slices->{$right_non_gap->to->id});
        
        
        # flanking coords are inconsistent,
        # which means that they come from different chains.
        # By chain filtering then, they must either come
        # from different target sequences, or be separable in the
        # same target sequence by a sequence-level gap. Either
        # way, we can nominally "fill" the gap. 
        #
        # However, if the gap coincides with the end of a block,
        # and furthermore if the block end conincides with the
        # end of a sequence-level piece in the target, it is
        # more appropriate to extend the exon into the existing
        # gap; in that case, we replace the gap with a fake
        # piece of alignment
        
        if (not check_consistent_coords($left_non_gap->to,
                                        $right_non_gap->to) or
            $ex_left->start > $ex_right->end or
            $ex_left->end   < $ex_right->start) {
          
          if ($left_non_gap->from->end == $this_pair->from->start - 1 and
              $right_non_gap->from->start == $this_pair->from->end + 1) {
            
            my $remove_coord = 1;
            my (@replace_coord);
            
            if ($left_non_gap->to->strand > 0 and 
                $ex_left->end - $left_non_gap->to->end <= $NEAR_CONTIG_END) {
              $remove_coord = 0;
              
              if (defined $ex_left_down and
                  $this_pair->to->length <= $ex_left_down->start - $ex_left->end - 1) {            
                push @replace_coord, Bio::EnsEMBL::Mapper::Coordinate
                    ->new($ex_left->id,
                          $ex_left->end + 1,
                          $ex_left->end + $this_pair->to->length,
                          $ex_left->strand);                  
              }
            } elsif ($left_non_gap->to->strand < 0 and 
                     $ex_left->start - $left_non_gap->to->start <= $NEAR_CONTIG_END) {
              $remove_coord = 0;
              
              if (defined $ex_left_up and 
                  $this_pair->to->length <= $ex_left_up->end - $ex_left->start - 1) {                
                push @replace_coord, Bio::EnsEMBL::Mapper::Coordinate
                    ->new($ex_left->id,
                          $ex_left->start - $this_pair->to->length,
                          $ex_left->start - 1,
                          $ex_left->strand);
              }            
            } 
            
            if ($right_non_gap->to->strand > 0 and
                $right_non_gap->to->start - $ex_right->start <= $NEAR_CONTIG_END) {
              $remove_coord = 0;
              
              if (defined $ex_right_up and
                  $this_pair->to->length <= $ex_right->start - $ex_right_up->end - 1) {
                push @replace_coord, Bio::EnsEMBL::Mapper::Coordinate
                    ->new($ex_right->id,
                          $ex_right->start - $this_pair->to->length,
                          $ex_right->start - 1,
                          $ex_right->strand);
              }
            } elsif ($right_non_gap->to->strand < 0 and
                     $ex_right->end - $right_non_gap->to->end <= $NEAR_CONTIG_END) {
              $remove_coord = 0;
              
              if (defined $ex_right_down and
                  $this_pair->to->length <= $ex_right_down->start - $ex_right->end - 1) {
                push @replace_coord, Bio::EnsEMBL::Mapper::Coordinate
                    ->new($ex_right->id,
                          $ex_right->end + 1,
                          $ex_right->end + $this_pair->to->length,
                          $ex_right->strand);
              }
            } 
            
            if ($remove_coord) {
              # gap does not align with the end of a contig; junk it
              $pairs_to_remove{$this_pair} = 1;
            } elsif (@replace_coord) {
              # arbitrarily chose the first one
              push @replacements, [$this_pair,
                                   $replace_coord[0]];
            }
            
          } elsif ($left_non_gap->from->end == $this_pair->from->start - 1) {
            if ($left_non_gap->to->strand > 0 and 
                $ex_left->end - $left_non_gap->to->end <= $NEAR_CONTIG_END) {
              
              if (defined $ex_left_down and
                  $this_pair->to->length <= $ex_left_down->start - $ex_left->end - 1) {
                push @replacements, [$this_pair,
                                     Bio::EnsEMBL::Mapper::Coordinate
                                     ->new($ex_left->id,
                                           $ex_left->end + 1,
                                           $ex_left->end + $this_pair->to->length,
                                           $ex_left->strand)];
              }
            } elsif ($left_non_gap->to->strand < 0 and 
                     $ex_left->start - $left_non_gap->to->start <= $NEAR_CONTIG_END) {
              
              if (defined $ex_left_up and 
                  $this_pair->to->length <= $ex_left_up->end - $ex_left->start - 1) {
                push @replacements, [$this_pair,
                                     Bio::EnsEMBL::Mapper::Coordinate
                                     ->new($ex_left->id,
                                           $ex_left->start - $this_pair->to->length,
                                           $ex_left->start - 1,
                                           $ex_left->strand)];
              }
            } else {
              # gap does not align with the end of a contig; junk it
              $pairs_to_remove{$this_pair} = 1;
            }
          } elsif ($right_non_gap->from->start == $this_pair->from->end + 1) {
            if ($right_non_gap->to->strand > 0 and 
                $right_non_gap->to->start - $ex_right->start <= $NEAR_CONTIG_END) {
              
              if (defined $ex_right_up and
                  $this_pair->to->length <= $ex_right->start - $ex_right_up->end - 1) {
                push @replacements, [$this_pair,
                                     Bio::EnsEMBL::Mapper::Coordinate
                                     ->new($ex_right->id,
                                           $ex_right->start - $this_pair->to->length,
                                           $ex_right->start - 1,
                                           $ex_right->strand)];
              }
            } elsif ($right_non_gap->to->strand < 0 and 
                     $ex_right->end - $right_non_gap->to->end <= $NEAR_CONTIG_END) {
              
              if (defined $ex_right_down and 
                  $this_pair->to->length <= $ex_right_down->start - $ex_right->end - 1) {
                push @replacements, [$this_pair, 
                                     Bio::EnsEMBL::Mapper::Coordinate
                                     ->new($ex_right->id,
                                           $ex_right->end + 1,
                                           $ex_right->end + $this_pair->to->length,
                                           $ex_right->strand)];
              }
            } else {
              # gap does not align with the end of a contig; junk it
              $pairs_to_remove{$this_pair} = 1;
            }
          }
          # else this gap is an isolate. It can be kept iff the coords are
          # on different chains, or on the same chain but on different
          # contigs; we've already determined that the components can
          # be separated, so fine          
          
        }
        else {
          $pairs_to_remove{$this_pair} = 1;
        }
      }
    }
    
    @all_coord_pairs = grep { not exists $pairs_to_remove{$_} } @all_coord_pairs;
    
    @replacements = sort { 
      $a->[1]->id cmp $b->[1]->id or
          $a->[1]->start <=> $b->[1]->start;    
    } @replacements;
    
    while(@replacements) {
      my $el = shift @replacements;
      my ($pair, $rep) = @$el;
      
      my $fill = 1;
      
      if (@replacements) {
        my $nel = shift @replacements;
        my ($npair, $nrep) = @$nel;
        
        if ($rep->id eq $nrep->id and
            $rep->start <= $nrep->end and
            $rep->end   >= $nrep->start) {
          # we have over-filled a gap. Remove these fills
          $fill = 0;
        } else {
          unshift @replacements, $nel;
        }
      }
      if ($fill) {
        $pair->to($rep);      
        push @coord_positions, $pair;
      }
    }
  }

  if (not $add_gaps) {
    @all_coord_pairs = grep { not $_->to->isa("Bio::EnsEMBL::Mapper::Gap") } @all_coord_pairs;
  }

  ############################################
  # TODO: ascertain conditions under which we have no coord_pairs left here
  # make sure that does not happen!
  #############################################

  # merge adjacent targets   
  #  we want to be able to account for small, frame-preserving 
  #  insertions in the target sequence with respect to the query. 
  #  To give the later, gene-projection code the opportunity to 
  #  "read through" these insertions, we have to merge togther 
  #  adjacent, consistent targets that are within this "maximum 
  # read-through" distance

  my @merged_pairs;

  for(my $i=0; $i<@all_coord_pairs; $i++) {
    my $this_pair = $all_coord_pairs[$i];

    if ($this_pair->to->isa("Bio::EnsEMBL::Mapper::Coordinate") and
        @merged_pairs and
        $merged_pairs[-1]->to->isa("Bio::EnsEMBL::Mapper::Coordinate") and 
        check_consistent_coords($merged_pairs[-1]->to,
                                $this_pair->to)) {

      my $dist = distance_between_coords($merged_pairs[-1]->to,
                                         $this_pair->to);
      
      if ($dist <= $MAX_READTHROUGH_DIST) {
        
        my $last_pair = pop @merged_pairs;

        my $new_from = merge_coords($last_pair->from,
                                    $this_pair->from);
        my $new_to = merge_coords($last_pair->to,
                                  $this_pair->to);
        
        # check that the new merged coord will not result in an overlap
        my $overlap = 0;
        foreach my $tg (@merged_pairs) {
          if ($tg->to->isa("Bio::EnsEMBL::Mapper::Coordinate") and
              $tg->to->id eq $new_to->id and
              $tg->to->start < $new_to->end and
              $tg->to->end   > $new_to->start) {
            $overlap = 1;
            last;
          }
        }
        if (not $overlap) {
          for (my $j=$i+1; $j < @all_coord_pairs; $j++) {
            my $tg = $all_coord_pairs[$j];
            if ($tg->to->isa("Bio::EnsEMBL::Mapper::Coordinate") and
                $tg->to->id eq $new_to->id and 
                $tg->to->start < $new_to->end and
                $tg->to->end   > $new_to->start) {
              $overlap = 1;
              last;
            }
          }
        }
        
        if ($overlap) {
          push @merged_pairs, $last_pair, $this_pair;
        } else {
          push @merged_pairs, Bio::EnsEMBL::Mapper::Pair->new($new_from, 
                                                                $new_to);
        }
      } else {
        push @merged_pairs, $this_pair;
      }
    }
    else {
      push @merged_pairs, $this_pair;
    }
  }
    
  #########################################################

  my $t_map = Bio::EnsEMBL::Mapper->new($TO_CS_NAME,
                                        $GENE_SCAFFOLD_CS_NAME); 
  my $q_map = Bio::EnsEMBL::Mapper->new($FROM_CS_NAME,
                                        $GENE_SCAFFOLD_CS_NAME);
  
  my ($seq, $last_end_pos) = ("", 0);
  for(my $i=0; $i < @merged_pairs; $i++) {
    my $pair = $merged_pairs[$i];

    if ($pair->to->isa("Bio::EnsEMBL::Mapper::Coordinate")) {            
      # the sequence itself        
      my $slice = $to_slices->{$pair->to->id};

      my $this_seq = $slice->subseq($pair->to->start, $pair->to->end);

      if ($pair->to->strand < 0) {
        reverse_comp(\$this_seq);
      }      
      $seq .= $this_seq;

      # and the map
      $t_map->add_map_coordinates($pair->to->id,
                                  $pair->to->start,
                                  $pair->to->end,
                                  $pair->to->strand,
                                  $GENE_SCAFFOLD_CS_NAME,
                                  $last_end_pos + 1,
                                  $last_end_pos + $pair->to->length);
    } else {
      # the sequence itself
      $seq .= ('n' x $pair->from->length);
      
      # and the map. This is a target gap we have "filled", so no position 
      # in target, but a position in query
      
      $q_map->add_map_coordinates($from_slice->seq_region_name,
                                  $pair->from->start,
                                  $pair->from->end,
                                  1,
                                  $GENE_SCAFFOLD_CS_NAME,
                                  $last_end_pos + 1,
                                  $last_end_pos + $pair->from->length);
    }

    # add padding between the pieces
    if ($i < @merged_pairs - 1) {
      $last_end_pos += 
          $pair->to->length + $INTERPIECE_PADDING;
      $seq .= ('n' x $INTERPIECE_PADDING);
    }
  }
  
  # now add of the original alignment pieces to the query map
  foreach my $pair (@coord_positions) {
    
    if ($pair->to->isa("Bio::EnsEMBL::Mapper::Coordinate")) {
      # get the gene_scaffold position from the target map
      my ($coord) = $t_map->map_coordinates($pair->to->id,
                                            $pair->to->start,
                                            $pair->to->end,
                                            $pair->to->strand,
                                            $TO_CS_NAME);

      $q_map->add_map_coordinates($from_slice->seq_region_name,
                                  $pair->from->start,
                                  $pair->from->end,
                                  1,
                                  $GENE_SCAFFOLD_CS_NAME,
                                  $coord->start,
                                  $coord->end);
    }
  }

  return ($seq, $q_map, $t_map);
}

#################################################

sub _projectable_features_from_transcripts {
  my ($map, $trans) = @_;

  my @all_good_exons;

  foreach my $tr (@$trans) {
    my @exons = sort {$a->start <=> $b->start} @{$tr->get_all_translateable_Exons};

    my $seen_good = 0;
    my @gap_exons;

    for(my $i = 0; $i < @exons; $i++) {
      my $e = $exons[$i];

      my @c = $map->map_coordinates($e->slice->seq_region_name,
                                    $e->start,
                                    $e->end,
                                    1,
                                    $FROM_CS_NAME);

      if ((scalar(@c) == 1 and 
          $c[0]->isa("Bio::EnsEMBL::Mapper::Gap")) or
          $e->length <= 3) {

        push @gap_exons, $e;
      } else {
        if ($seen_good) {
          push @all_good_exons, @gap_exons;
        }
        @gap_exons = ();

        push @all_good_exons, $e;
        $seen_good = 1;
      }
    }
  }

  my @features;     
  @all_good_exons = sort { $a->start <=> $b->start } @all_good_exons;

  foreach my $e (@all_good_exons) {
    if (not @features or
        $features[-1]->end < $e->start - 1) {
      push @features, Bio::EnsEMBL::Feature->
          new(-start  => $e->start,
              -end    => $e->end,
              -slice  => $e->slice);
    } else {
      if ($e->end > $features[-1]->end) {
        $features[-1]->end($e->end);
      }
    }
  }

  return \@features;
}

#################################################

sub _make_alignment_mapper {
  my ($gen_al_blocks) = @_;

  my $mapper = Bio::EnsEMBL::Mapper->new($FROM_CS_NAME,
                                         $TO_CS_NAME);

  foreach my $bl (@$gen_al_blocks) {
    foreach my $ugbl (@{$bl->get_all_ungapped_GenomicAlignBlocks}) {      
      my ($from_bl) = $ugbl->reference_genomic_align;
      my ($to_bl)   = @{$ugbl->get_all_non_reference_genomic_aligns};

      $mapper->add_map_coordinates($from_bl->dnafrag->name,
                                   $from_bl->dnafrag_start,
                                   $from_bl->dnafrag_end,
                                   $from_bl->dnafrag_strand * $to_bl->dnafrag_strand,
                                   $to_bl->dnafrag->name,
                                   $to_bl->dnafrag_start,
                                   $to_bl->dnafrag_end);
    }
  }

  return $mapper;
}


##############################################
# Get/Sets
##############################################

sub alignment_mapper {
  my ($self, $val) = @_;

  if (defined $val) {
    $self->{_alignment_mapper} = $val;
  }

  return $self->{_alignment_mapper};
}


sub from_slice {
  my ($self, $val) = @_;

  if (defined $val) {
    $self->{_from_slice} = $val;
  }

  return $self->{_from_slice};
}


sub from_mapper {
  my ($self, $val) = @_;

  if (defined $val) {
    $self->{_from_mapper} = $val;
  }

  return $self->{_from_mapper};
}


sub to_slices {
  my ($self, $val) = @_;

  if (defined $val) {
    $self->{_to_slices} = $val;
  }

  return $self->{_to_slices};
}


sub to_mapper {
  my ($self, $val) = @_;

  if (defined $val) {
    $self->{_to_mapper} = $val;
  }
  return $self->{_to_mapper};

}



1;
