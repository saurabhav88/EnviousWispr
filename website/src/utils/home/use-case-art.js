// The nine "See yourself using EnviousWispr" illustrations, one named import
// each, keyed by the file name cases.json uses, so a typo in the JSON fails
// the build instead of silently matching nothing. UseCases.astro derives the
// resized webp variants from these; the masters themselves must never be
// read as properties (see the note there) or they are emitted into dist.
import accessibility from '../../assets/home/accessibility.webp';
import business from '../../assets/home/business.webp';
import developer from '../../assets/home/developer.webp';
import medical from '../../assets/home/medical.png';
import parent from '../../assets/home/parent.webp';
import podcaster from '../../assets/home/podcaster.webp';
import remote from '../../assets/home/remote.webp';
import student from '../../assets/home/student.webp';
import writer from '../../assets/home/writer.webp';

export const useCaseArt = {
  'accessibility.webp': accessibility,
  'business.webp': business,
  'developer.webp': developer,
  'medical.png': medical,
  'parent.webp': parent,
  'podcaster.webp': podcaster,
  'remote.webp': remote,
  'student.webp': student,
  'writer.webp': writer,
};
